// OpenVision - AIBackendSettingsView.swift
// AI backend selection and configuration

import SwiftUI

struct AIBackendSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - Body

    var body: some View {
        Form {
            // Backend Selection
            Section {
                ForEach(AIBackendType.allCases, id: \.self) { backend in
                    Button {
                        settingsManager.settings.aiBackend = backend
                    } label: {
                        HStack {
                            Image(systemName: backend.icon)
                                .foregroundColor(Theme.accent)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(backend.displayName)
                                    .foregroundColor(.primary)
                                Text(backend.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if settingsManager.settings.aiBackend == backend {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("Choose Your AI")
            } footer: {
                Text("Яндекс Облако работает в России без VPN и Mac. OpenClaw offers more tools; Gemini Live has lower latency.")
            }

            // Backend Configuration Links
            Section {
                NavigationLink {
                    YandexCloudSettingsView()
                } label: {
                    HStack {
                        Label("Яндекс Облако", systemImage: "cloud")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isYandexConfigured)
                    }
                }

                NavigationLink {
                    OpenClawSettingsView()
                } label: {
                    HStack {
                        Label("OpenClaw Settings", systemImage: "terminal")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isOpenClawConfigured)
                    }
                }

                NavigationLink {
                    GeminiSettingsView()
                } label: {
                    HStack {
                        Label("Gemini Settings", systemImage: "waveform")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isGeminiConfigured)
                    }
                }

                NavigationLink {
                    OpenAISettingsView()
                } label: {
                    HStack {
                        Label("OpenAI Settings", systemImage: "sparkles")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isOpenAIConfigured)
                    }
                }

                NavigationLink {
                    AppleIntelligenceSettingsView()
                } label: {
                    HStack {
                        Label("Apple Intelligence", systemImage: "apple.logo")
                        Spacer()
                        configurationBadge(configured: AppleFoundationService.shared.isAvailable)
                    }
                }

                NavigationLink {
                    GemmaSettingsView()
                } label: {
                    HStack {
                        Label("Local Models", systemImage: "cpu")
                        Spacer()
                        configurationBadge(configured: settingsManager.settings.isLocalGemmaConfigured)
                    }
                }
            } header: {
                Text("Configuration")
            }
        }
        .navigationTitle("AI Backend")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func configurationBadge(configured: Bool) -> some View {
        if configured {
            HStack(spacing: 4) {
                Text("Configured")
                    .font(.caption)
                    .foregroundColor(.green)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        } else {
            HStack(spacing: 4) {
                Text("Not configured")
                    .font(.caption)
                    .foregroundColor(.orange)
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Yandex Cloud

/// Yandex Cloud setup: two fields, a one-tap switch of brain + voice, and a connection check
/// that explains failures in plain Russian.
struct YandexCloudSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager

    @State private var apiKey: String = ""
    @State private var folderID: String = ""
    @State private var checkResult: String?
    @State private var isChecking = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API-ключ").font(.caption).foregroundColor(.secondary)
                    SecureField("AQVN…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("ID каталога").font(.caption).foregroundColor(.secondary)
                    TextField("b1g…", text: $folderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Доступ")
            } footer: {
                Text("Ключ хранится в защищённом хранилище iPhone (Keychain). Запросы не сохраняются на серверах Яндекса.")
            }

            Section {
                Button {
                    save()
                    settingsManager.settings.aiBackend = .yandex
                    settingsManager.settings.ttsEngine = .yandex
                    settingsManager.saveNow()
                    checkResult = "Готово: мозг и голос переключены на Яндекс."
                } label: {
                    Label("Использовать Яндекс для всего", systemImage: "checkmark.seal")
                }
                .disabled(apiKey.isEmpty || folderID.isEmpty)

                Button {
                    save()
                    Task { await check() }
                } label: {
                    HStack {
                        Label("Проверить подключение", systemImage: "antenna.radiowaves.left.and.right")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(apiKey.isEmpty || folderID.isEmpty || isChecking)

                if let checkResult {
                    Text(checkResult).font(.callout)
                }
            } footer: {
                Text("«Использовать для всего» включает Яндекс и для ответов, и для голоса Дубины.")
            }

            Section {
                LabeledContent("Разговор", value: settingsManager.settings.yandexTextModel)
                LabeledContent("Фото", value: settingsManager.settings.yandexVisionModel)
            } header: {
                Text("Модели")
            }
        }
        .navigationTitle("Яндекс Облако")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settingsManager.settings.yandexAPIKey
            folderID = settingsManager.settings.yandexFolderID
        }
        .onDisappear { save() }
    }

    private func save() {
        settingsManager.settings.yandexAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.yandexFolderID = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.saveNow()
    }

    /// One tiny request each to the chat model and SpeechKit; translate the outcome.
    private func check() async {
        isChecking = true
        defer { isChecking = false }
        let settings = settingsManager.settings

        var chat = URLRequest(url: URL(string: YandexCloud.baseURL + "/chat/completions")!)
        chat.httpMethod = "POST"
        chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (header, value) in YandexCloud.headers(settings) { chat.setValue(value, forHTTPHeaderField: header) }
        chat.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": YandexCloud.modelURI(settings.yandexTextModel, settings),
            "messages": [["role": "user", "content": "Ответь одним словом: готов"]],
            "max_tokens": 10
        ])
        chat.timeoutInterval = 20
        let chatStatus = await status(of: chat)

        var tts = URLRequest(url: URL(string: YandexCloud.ttsURL)!)
        tts.httpMethod = "POST"
        tts.setValue("Api-Key \(settings.yandexAPIKey)", forHTTPHeaderField: "Authorization")
        tts.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tts.setValue("false", forHTTPHeaderField: "x-data-logging-enabled")
        let folder = settings.yandexFolderID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        tts.httpBody = Data("text=%D0%B3%D0%BE%D1%82%D0%BE%D0%B2&lang=ru-RU&voice=\(settings.yandexVoice)&format=mp3&folderId=\(folder)".utf8)
        tts.timeoutInterval = 20
        let ttsStatus = await status(of: tts)

        checkResult = "Ответы: \(Self.explain(chatStatus))\nГолос: \(Self.explain(ttsStatus))"
    }

    private func status(of request: URLRequest) async -> Int {
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return -1 }
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private static func explain(_ status: Int) -> String {
        switch status {
        case 200: return "работает ✓"
        case 401: return "ключ не подходит — проверьте, что скопирован полностью"
        case 403: return "нет прав — у сервисного аккаунта не хватает роли (нужна ai.editor)"
        case 404: return "не найдено — проверьте ID каталога"
        case 402, 429: return "лимит или баланс — проверьте платёжный аккаунт"
        case -1: return "нет связи с Яндексом — проверьте интернет"
        default: return "ошибка \(status)"
        }
    }
}

#Preview {
    NavigationStack {
        AIBackendSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
