// OpenVision - TTSService.swift
// Text-to-speech service using AVSpeechSynthesizer

import AVFoundation
import Foundation

/// Text-to-speech service for OpenClaw mode
@MainActor
final class TTSService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = TTSService()

    // MARK: - Published State

    @Published var isSpeaking: Bool = false

    // MARK: - Callbacks

    /// Called when speech starts
    var onSpeechStarted: (() -> Void)?

    /// Called when speech ends
    var onSpeechEnded: (() -> Void)?

    // MARK: - Speech Synthesizer

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Streaming state

    /// Utterances enqueued but not yet finished. `isSpeaking` only drops to false when this
    /// hits 0 AND no more chunks are coming — so it doesn't flap between queued sentences.
    private var pendingUtterances = 0

    /// True while a streamed reply is still being fed sentence-by-sentence. Keeps `isSpeaking`
    /// latched even if the audio queue momentarily drains faster than the LLM produces text.
    private var streamingActive = false

    // MARK: - Voice Selection

    private var selectedVoice: AVSpeechSynthesisVoice? {
        // Check if user has selected a specific voice
        if let identifier = SettingsManager.shared.settings.selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }

        // Fall back to default English voice
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Russian replies need a Russian voice — an English voice reads Cyrillic as gibberish or
    /// skips it. Keep the user's chosen voice when it already speaks Russian.
    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let isCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        guard isCyrillic else { return selectedVoice }
        if let chosen = selectedVoice, chosen.language.hasPrefix("ru") { return chosen }
        return Self.availableVoices(for: "ru").first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    /// Get all available voices for a language
    static func availableVoices(for languageCode: String = "en") -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) }
            .sorted { v1, v2 in
                // Sort by quality (premium first), then by name
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }

    /// Get display name for a voice quality
    static func qualityDisplayName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// Speak text (single-shot: replaces anything currently playing).
    func speak(_ text: String) {
        stop()
        enqueue(text)
    }

    /// Ambient narration (watch loop): speaks only into silence and never preempts — `speak`
    /// stops the synthesizer first, which cut replies off mid-sentence when a watch line landed
    /// during one. Dropped lines are fine; the next scene change describes again.
    func speakAmbient(_ text: String) {
        guard !isSpeaking, !streamingActive else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(trimmed)
    }

    // MARK: - Streaming (sentence-by-sentence)

    /// Begin a streamed reply. Clears the queue and latches `isSpeaking` true so the recognizer
    /// stays paused across the gaps between sentences while the LLM is still generating.
    func beginStreaming() {
        stop()
        streamingActive = true
        isSpeaking = true
        onSpeechStarted?()
    }

    /// Enqueue one sentence without interrupting what's already queued. AVSpeechSynthesizer plays
    /// queued utterances back-to-back, so this pipelines speech behind the LLM as it streams.
    func speakChunk(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(trimmed)
    }

    /// Signal that no more sentences are coming. Releases the latch once the queue drains.
    func endStreaming() {
        streamingActive = false
        if pendingUtterances == 0 {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    /// Build an utterance with the selected voice and hand it to the synthesizer's queue.
    private func enqueue(_ text: String) {
        if useCloudVoice {
            pendingUtterances += 1
            openAIQueue.append(text)
            startOpenAIPumpIfNeeded()
            return
        }
        speakWithSystemVoice(text)
    }

    /// Apple system voice. `alreadyCounted` is true for an OpenAI fallback, whose sentence was
    /// already counted in `pendingUtterances` when it was queued.
    private func speakWithSystemVoice(_ text: String, alreadyCounted: Bool = false) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        if !alreadyCounted { pendingUtterances += 1 }
        synthesizer.speak(utterance)
    }

    // MARK: - Cloud voice (OpenAI or Yandex SpeechKit)
    //
    // Same contract as the system voice — `isSpeaking`, `pendingUtterances`, `onSpeechStarted`/
    // `onSpeechEnded` — so barge-in pausing and streaming replies work unchanged. Sentences are
    // synthesized in order; the next one is fetched while the current one plays to hide latency.

    private var openAIQueue: [String] = []
    private var openAIPump: Task<Void, Never>?
    private var openAIPlayer: AVAudioPlayer?
    private var openAIPlaybackDone: CheckedContinuation<Void, Never>?
    /// Bumped by `stop()`; a pump from an older generation exits without touching state.
    private var openAIGeneration = 0

    /// A cloud voice is selected and has credentials (OpenAI key, or Yandex key + folder).
    private var useCloudVoice: Bool {
        let settings = SettingsManager.shared.settings
        switch settings.ttsEngine {
        case .openAI: return !settings.openAIAPIKey.isEmpty
        case .yandex: return settings.isYandexConfigured
        default: return false
        }
    }

    /// Synthesize one sentence with the selected cloud voice.
    private func fetchCloudSpeech(_ text: String) -> Task<Data?, Never> {
        SettingsManager.shared.settings.ttsEngine == .yandex ? fetchYandexSpeech(text) : fetchOpenAISpeech(text)
    }

    /// Yandex SpeechKit (REST API v1): a form POST that returns the MP3 bytes directly.
    private func fetchYandexSpeech(_ text: String) -> Task<Data?, Never> {
        let settings = SettingsManager.shared.settings
        var fields: [(String, String)] = [
            ("text", text),
            ("lang", "ru-RU"),
            ("voice", settings.yandexVoice),
            ("speed", String(format: "%.1f", settings.yandexVoiceSpeed)),
            ("format", "mp3"),
            ("folderId", settings.yandexFolderID.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        // Only some voices have roles; sending one to a voice without roles is an error.
        if ["ermil", "zahar", "jane", "omazh", "marina"].contains(settings.yandexVoice), !settings.yandexVoiceRole.isEmpty {
            fields.append(("emotion", settings.yandexVoiceRole))
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        let key = settings.yandexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return Task.detached {
            guard let url = URL(string: YandexCloud.ttsURL) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("Api-Key \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("false", forHTTPHeaderField: "x-data-logging-enabled")
            request.httpBody = Data(body.utf8)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    print("[TTS] Yandex SpeechKit HTTP \(status)")
                    return nil
                }
                return data
            } catch {
                if !Task.isCancelled { print("[TTS] Yandex SpeechKit request failed: \(error.localizedDescription)") }
                return nil
            }
        }
    }

    private func startOpenAIPumpIfNeeded() {
        guard openAIPump == nil else { return }
        let generation = openAIGeneration
        openAIPump = Task { [weak self] in
            await self?.runOpenAIPump(generation: generation)
        }
    }

    private func runOpenAIPump(generation: Int) async {
        var prefetched: (text: String, audio: Task<Data?, Never>)?
        while generation == openAIGeneration {
            let current: (text: String, audio: Task<Data?, Never>)
            if let next = prefetched {
                current = next
                prefetched = nil
            } else if !openAIQueue.isEmpty {
                let text = openAIQueue.removeFirst()
                current = (text, fetchCloudSpeech(text))
            } else {
                break
            }

            let audio = await current.audio.value
            guard generation == openAIGeneration else { break }

            if !openAIQueue.isEmpty {
                let text = openAIQueue.removeFirst()
                prefetched = (text, fetchCloudSpeech(text))
            }

            if let audio, await playOpenAIAudio(audio, generation: generation) {
                guard generation == openAIGeneration else { break }
                finishOneUtterance()
            } else {
                guard generation == openAIGeneration else { break }
                // Network/API failure: say it with the system voice rather than drop it. The
                // synthesizer delegate settles this sentence's count when it finishes.
                print("[TTS] cloud voice unavailable — falling back to system voice")
                speakWithSystemVoice(current.text, alreadyCounted: true)
                while synthesizer.isSpeaking && generation == openAIGeneration {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        prefetched?.audio.cancel()
        if generation == openAIGeneration { openAIPump = nil }
    }

    /// One OpenAI sentence finished playing — same bookkeeping as the synthesizer's didFinish.
    private func finishOneUtterance() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if pendingUtterances == 0 && !streamingActive {
            isSpeaking = false
            onSpeechEnded?()
        }
    }

    private func fetchOpenAISpeech(_ text: String) -> Task<Data?, Never> {
        let settings = SettingsManager.shared.settings
        let base = settings.openAIBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let key = settings.openAIAPIKey
        let body: [String: Any] = [
            "model": settings.openAITTSModel,
            "voice": settings.openAITTSVoice,
            "input": text,
            "instructions": settings.openAITTSInstructions,
            "response_format": "mp3"
        ]
        let payload = try? JSONSerialization.data(withJSONObject: body)
        return Task.detached {
            guard let url = URL(string: base + "/audio/speech"), let payload else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    // Log only the error code — the message can echo part of the API key.
                    let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                    print("[TTS] OpenAI speech HTTP \(status), code: \(error?["code"] as? String ?? error?["type"] as? String ?? "unknown")")
                    return nil
                }
                return data
            } catch {
                if !Task.isCancelled { print("[TTS] OpenAI speech request failed: \(error.localizedDescription)") }
                return nil
            }
        }
    }

    /// Play one synthesized sentence; returns false if the audio couldn't be played.
    private func playOpenAIAudio(_ data: Data, generation: Int) async -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        openAIPlayer = player
        guard player.play() else {
            openAIPlayer = nil
            return false
        }
        MetricsCollector.shared.markFirstAudio()
        if !isSpeaking {
            isSpeaking = true
            onSpeechStarted?()
        }
        await withCheckedContinuation { continuation in
            if generation == openAIGeneration && player.isPlaying {
                openAIPlaybackDone = continuation
            } else {
                continuation.resume()
            }
        }
        openAIPlayer = nil
        return true
    }

    private func resumeOpenAIPlaybackWaiter() {
        openAIPlaybackDone?.resume()
        openAIPlaybackDone = nil
    }

    /// Stop speaking and clear the queue.
    func stop() {
        openAIGeneration += 1
        openAIQueue.removeAll()
        openAIPump?.cancel()
        openAIPump = nil
        openAIPlayer?.stop()
        openAIPlayer = nil
        resumeOpenAIPlaybackWaiter()

        synthesizer.stopSpeaking(at: .immediate)
        streamingActive = false
        pendingUtterances = 0
        isSpeaking = false
    }

    /// Pause speaking
    func pause() {
        openAIPlayer?.pause()
        synthesizer.pauseSpeaking(at: .word)
    }

    /// Continue speaking
    func continueSpeaking() {
        openAIPlayer?.play()
        synthesizer.continueSpeaking()
    }
}

// MARK: - AVAudioPlayerDelegate (cloud voice)

extension TTSService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.openAIPlayer else { return }
            self.resumeOpenAIPlaybackWaiter()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            print("[TTS] OpenAI audio decode error: \(error?.localizedDescription ?? "unknown")")
            guard player === self.openAIPlayer else { return }
            self.resumeOpenAIPlaybackWaiter()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // The moment audio actually begins — the honest end of the wearer's wait. Marked here,
            // not where the view model hands text over: hand-off-time marking excluded synthesis
            // entirely, which made TTS TTFB structurally zero and perceived latency optimistic.
            // First-wins per turn, and gated inside the collector on the turn having requested
            // TTS, so later sentences and unrelated system utterances can't misattribute.
            MetricsCollector.shared.markFirstAudio()
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onSpeechStarted?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            // Only truly "done" when the queue is empty AND no more sentences are coming.
            if self.pendingUtterances == 0 && !self.streamingActive {
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtterances = max(0, self.pendingUtterances - 1)
            if self.pendingUtterances == 0 {
                self.streamingActive = false
                self.isSpeaking = false
                self.onSpeechEnded?()
            }
        }
    }
}
