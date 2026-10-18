// OpenVision - SettingsManager.swift
// Singleton manager for settings persistence with debounced auto-save

import Foundation
import Combine
import Security

/// Manages app settings with JSON persistence and debounced saving
@MainActor
final class SettingsManager: ObservableObject {
    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - Published Properties

    /// Current app settings - changes trigger debounced save
    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue {
                scheduleSave()
            }
        }
    }

    // MARK: - Private Properties

    private let settingsURL: URL
    private var saveTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.5

    // MARK: - Callbacks

    /// Called when settings change (for live session updates)
    var onSettingsChanged: ((AppSettings) -> Void)?

    // MARK: - Initialization

    private init() {
        // Set up file URL
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        settingsURL = documentsURL.appendingPathComponent("settings.json")

        // Load existing settings or create defaults, then fill the secrets from the Keychain.
        var loaded = Self.loadSettings(from: settingsURL)
        let movedToKeychain = Self.mergeSecretsFromKeychain(into: &loaded)
        settings = loaded

        // An older settings.json still holds plaintext keys: rewrite it without them.
        if movedToKeychain {
            print("[SettingsManager] Moved secrets from settings.json to the Keychain")
            performSave()
        }

        print("[SettingsManager] Initialized with settings from: \(settingsURL.path)")
    }

    // MARK: - Secrets

    /// Settings fields that are secrets. They are kept in the Keychain and written to
    /// settings.json as empty strings — the JSON file is plain text and goes into backups.
    private static let secretFields: [(account: String, keyPath: WritableKeyPath<AppSettings, String>)] = [
        ("openAIAPIKey", \.openAIAPIKey),
        ("yandexAPIKey", \.yandexAPIKey),
        ("openClawAuthToken", \.openClawAuthToken),
        ("geminiAPIKey", \.geminiAPIKey),
        ("tavilyAPIKey", \.tavilyAPIKey),
        ("telemetryToken", \.telemetryToken),
        ("telemetryPassword", \.telemetryPassword)
    ]

    /// Fill secret fields from the Keychain. A secret still present in the file (older build, or
    /// a failed Keychain write) is the newer value: it is moved into the Keychain. Returns true
    /// when the file held any secret, so the caller can rewrite it without them.
    private static func mergeSecretsFromKeychain(into settings: inout AppSettings) -> Bool {
        var fileHadSecrets = false
        for field in secretFields {
            let fromFile = settings[keyPath: field.keyPath]
            if !fromFile.isEmpty {
                fileHadSecrets = true
                KeychainStore.set(fromFile, for: field.account)
            } else {
                settings[keyPath: field.keyPath] = KeychainStore.string(for: field.account) ?? ""
            }
        }
        return fileHadSecrets
    }

    // MARK: - Public Methods

    /// Save settings immediately (use on app background/disappear)
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        performSave()
    }

    /// Reset settings to defaults
    func resetToDefaults() {
        settings = AppSettings()
        saveNow()
    }

    // MARK: - Memory Management

    /// Add or update a memory
    func setMemory(key: String, value: String) {
        settings.memories[key] = value
    }

    /// Delete a memory
    func deleteMemory(key: String) {
        settings.memories.removeValue(forKey: key)
    }

    /// Rename a memory key
    func renameMemory(oldKey: String, newKey: String) {
        guard let value = settings.memories[oldKey] else { return }
        settings.memories.removeValue(forKey: oldKey)
        settings.memories[newKey] = value
    }

    // MARK: - Private Methods

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // NOTE: was UInt64(debounceInterval) which is UInt64(0.5) == 0 — no delay. Multiply into
            // nanoseconds first so the debounce actually coalesces rapid edits (e.g. typing a key).
            let seconds = self?.debounceInterval ?? 0.5
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performSave()
            self?.onSettingsChanged?(self?.settings ?? AppSettings())
        }
    }

    private func performSave() {
        do {
            // Secrets go to the Keychain; the file gets them blanked. If the Keychain refuses a
            // write, keep that one secret in the file rather than lose it (moved on next launch).
            var onDisk = settings
            for field in Self.secretFields {
                let value = settings[keyPath: field.keyPath]
                if KeychainStore.string(for: field.account) ?? "" == value || KeychainStore.set(value, for: field.account) {
                    onDisk[keyPath: field.keyPath] = ""
                } else {
                    print("[SettingsManager] Keychain write failed for \(field.account) — kept in file")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(onDisk)
            try data.write(to: settingsURL, options: .atomic)
            print("[SettingsManager] Settings saved")
        } catch {
            print("[SettingsManager] Error saving settings: \(error)")
        }
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            print("[SettingsManager] No settings file, using defaults")
            return createDefaultSettings()
        }

        // Strict decode first — succeeds when every field is present.
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            print("[SettingsManager] Loaded settings from file")
            return settings
        }

        // Lenient fallback. Synthesized Codable throws on ANY missing key, so a settings.json
        // written by an older build (before a field was added) would otherwise reset EVERYTHING to
        // defaults — silently wiping saved API keys. Instead, overlay the on-disk values onto the
        // defaults' JSON (so present keys keep the user's value, missing keys fall back to default)
        // and decode the merge. This makes adding new settings fields non-destructive.
        let defaults = createDefaultSettings()
        if let defaultsData = try? JSONEncoder().encode(defaults),
           var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any],
           let onDisk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in onDisk { merged[key] = value }   // on-disk value wins where present
            if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData) {
                print("[SettingsManager] Loaded settings via lenient merge (older file, missing fields filled)")
                return settings
            }
        }

        print("[SettingsManager] Could not decode settings even leniently — using defaults")
        return defaults
    }

    private static func createDefaultSettings() -> AppSettings {
        var settings = AppSettings()

        // Apply any build-time defaults from Config
        if !Config.defaultOpenClawGatewayURL.isEmpty {
            settings.openClawGatewayURL = Config.defaultOpenClawGatewayURL
        }
        if !Config.defaultOpenClawAuthToken.isEmpty {
            settings.openClawAuthToken = Config.defaultOpenClawAuthToken
        }
        if !Config.defaultGeminiAPIKey.isEmpty {
            settings.geminiAPIKey = Config.defaultGeminiAPIKey
        }

        return settings
    }
}

// MARK: - Keychain

/// Small wrapper over the iOS Keychain for the app's secrets (API keys, tokens, device keys).
/// "AfterFirstUnlockThisDeviceOnly": readable in the background with the phone locked (the
/// assistant keeps working from a pocket), never included in backups or moved to another device.
enum KeychainStore {
    private static let service = "com.openvision.secrets"

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Store `data` (nil or empty deletes the item). Returns false if the Keychain refused.
    @discardableResult
    static func set(_ data: Data?, for account: String) -> Bool {
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = baseQuery(account).merging(attributes) { $1 }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        set(value.isEmpty ? nil : Data(value.utf8), for: account)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
