// OpenVision - AppSettings.swift
// Settings data model with Codable support for JSON persistence

import Foundation

/// The type of AI backend to use
enum AIBackendType: String, Codable, CaseIterable {
    case openClaw = "openclaw"
    case geminiLive = "gemini_live"
    case openAI = "openai"
    case appleFoundation = "apple_foundation"
    case localGemma = "local_gemma"
    case yandex = "yandex"

    var displayName: String {
        switch self {
        case .openClaw: return "OpenClaw"
        case .geminiLive: return "Gemini Live"
        case .openAI: return "OpenAI"
        case .appleFoundation: return "Apple Intelligence"
        case .localGemma: return "Local (MLX)"
        case .yandex: return "Яндекс Облако"
        }
    }

    var description: String {
        switch self {
        case .openClaw:
            return "Wake word activation, 56+ tools, task execution"
        case .geminiLive:
            return "Real-time voice + vision, continuous conversation"
        case .openAI:
            return "GPT-4o — cloud text + vision (OpenAI-compatible)"
        case .appleFoundation:
            return "On-device Apple model — private, no download (iOS 26+)"
        case .localGemma:
            return "On-device Gemma 4 — private, offline, no API cost"
        case .yandex:
            return "Alice AI + фото + поиск + голос SpeechKit — работает в России, один счёт"
        }
    }

    var icon: String {
        switch self {
        case .openClaw: return "terminal"
        case .geminiLive: return "waveform"
        case .openAI: return "sparkles"
        case .appleFoundation: return "apple.logo"
        case .localGemma: return "cpu"
        case .yandex: return "cloud"
        }
    }
}

/// Which text-to-speech engine to use.
enum TTSEngineType: String, Codable, CaseIterable, Identifiable {
    case appleSystem = "apple"
    case kokoro = "kokoro"
    case openAI = "openai"
    case yandex = "yandex"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleSystem: return "Apple (system voice)"
        case .kokoro: return "Kokoro (natural, on-device)"
        case .openAI: return "OpenAI (natural, cloud)"
        case .yandex: return "Яндекс SpeechKit"
        }
    }
}

/// App settings persisted to Documents/settings.json
struct AppSettings: Codable, Equatable {
    // MARK: - AI Backend Selection

    /// Which AI backend to use
    var aiBackend: AIBackendType = .openClaw

    // MARK: - OpenClaw Configuration

    /// OpenClaw gateway WebSocket URL (e.g., "wss://openclaw.example.com")
    var openClawGatewayURL: String = ""

    /// OpenClaw authentication token
    var openClawAuthToken: String = ""

    // MARK: - Gemini Live Configuration

    /// Google Gemini API key
    var geminiAPIKey: String = ""

    // MARK: - OpenAI Configuration

    /// OpenAI (or OpenAI-compatible) API key.
    var openAIAPIKey: String = ""

    /// Chat model id. gpt-4o-mini is cheap and supports vision — a good default for testing.
    var openAIModel: String = "gpt-4o-mini"

    // MARK: - Yandex Cloud (AI Studio + SpeechKit)

    /// Yandex Cloud API key (service account). Stored in the Keychain, never in settings.json.
    var yandexAPIKey: String = ""

    /// Yandex Cloud folder ID ("ID каталога") the models are billed to.
    var yandexFolderID: String = ""

    /// Conversation model (AI Studio common instance).
    var yandexTextModel: String = "aliceai-llm"

    /// Model used when photos are attached — the image-capable one.
    var yandexVisionModel: String = "qwen3.6-35b-a3b"

    /// SpeechKit voice and role. Male voices available over the REST API: ermil, filipp, zahar, madi_ru.
    var yandexVoice: String = "ermil"
    var yandexVoiceRole: String = "neutral"
    var yandexVoiceSpeed: Double = 1.0

    /// Who the assistant is in the direct OpenAI mode — name, manner, how it addresses the user.
    /// Custom Instructions are appended after it.
    var assistantPersona: String = "Тебя зовут Дубина. Ты — голосовой ИИ-ассистент в умных очках Ray-Ban Meta, в духе невозмутимого ИИ-дворецкого: спокойный, учтивый, уверенный, с лёгкой сдержанной иронией; сарказм и фамильярность — нет. Обращайся к пользователю «сэр». Отвечай на языке пользователя (обычно по-русски)."

    /// API base URL. Override to point at any OpenAI-compatible endpoint (OpenRouter, a local
    /// server, Azure-style gateways, etc.). No trailing slash.
    var openAIBaseURL: String = "https://api.openai.com/v1"

    /// Realtime model id used for live audio + video mode (GA gpt-realtime).
    var openAIRealtimeModel: String = "gpt-realtime"

    /// Voice used by the OpenAI Realtime backend.
    var openAIRealtimeVoice: String = "marin"

    // MARK: - Web Search

    /// Tavily API key (free tier). When set, web search uses Tavily (real live content, built for
    /// LLMs) as the primary source, falling back to keyless DuckDuckGo otherwise.
    var tavilyAPIKey: String = ""

    // MARK: - Local Gemma Configuration

    /// HuggingFace repo id of the on-device Gemma 4 model to load.
    /// Matches `GemmaLocalModel.e2b.modelId` (note the validated capital-E2B casing).
    var localGemmaModelId: String = "mlx-community/gemma-4-E2B-it-4bit"

    /// Whether the selected Gemma model has finished downloading and is ready to load.
    /// Set by the model-manager / GemmaLocalService once the snapshot is on disk.
    var localGemmaModelReady: Bool = false

    // MARK: - Voice Settings

    /// Wake word phrase (default: "Ok Vision")
    var wakeWord: String = "Ok Vision"

    /// Whether wake word detection is enabled (OpenClaw mode only)
    var wakeWordEnabled: Bool = true

    /// Play activation chime on wake word detection
    var playActivationSound: Bool = true

    /// Conversation timeout in seconds (auto-end after silence)
    var conversationTimeout: TimeInterval = 30

    /// Selected TTS voice identifier for the Apple system voice (nil = system default)
    var selectedVoiceIdentifier: String? = nil

    /// Which TTS engine to speak with. Apple (system voice) is the default and always available;
    /// Kokoro is on-device neural TTS (natural, offline) once its model is downloaded.
    var ttsEngine: TTSEngineType = .appleSystem

    /// Selected Kokoro voice (e.g. "af_heart"). First letter: a = American, b = British.
    var kokoroVoice: String = "af_heart"

    /// OpenAI speech voice (gpt-4o-mini-tts). Uses the OpenAI key/base URL above.
    var openAITTSVoice: String = "onyx"

    /// OpenAI speech model.
    var openAITTSModel: String = "gpt-4o-mini-tts"

    /// How the OpenAI voice should sound — gpt-4o-mini-tts follows these delivery instructions.
    var openAITTSInstructions: String = "Говори как невозмутимый, интеллигентный ИИ-дворецкий: спокойно, размеренно, вежливо, с лёгкой суховатой иронией. Чёткая дикция, низкий бархатный тембр, без излишних эмоций."

    // MARK: - Telemetry (opt-in, self-hosted)

    /// Push runtime metrics to your own InfluxDB. OFF by default and inert until a URL is set.
    /// Sends timings and device health only — never transcripts, replies, or tool arguments.
    var telemetryEnabled: Bool = false
    /// Base URL of your InfluxDB, e.g. "http://192.168.1.20:8086". Use the LAN IP or a `.local`
    /// name, never localhost — on the phone that would be the phone.
    var telemetryURL: String = ""
    var telemetryBucket: String = "metrics"
    var telemetryOrg: String = "openvision"
    /// InfluxDB v2 API token. Preferred; when empty the username/password below are used (v1).
    var telemetryToken: String = ""
    var telemetryUsername: String = ""
    var telemetryPassword: String = ""
    /// Tag on every point so several devices stay distinguishable in Grafana.
    var telemetryDeviceName: String = "iphone"

    /// Prefer the glasses' Bluetooth microphone for voice input when they're the connected audio
    /// device — true hands-free. Falls back to the phone mic automatically when the glasses aren't
    /// the audio route. Turn off to always use the phone. (Glasses mic uses more battery.)
    var preferGlassesMic: Bool = true

    // MARK: - AI Customization

    /// Custom instructions appended to AI system prompt
    var userPrompt: String = ""

    /// Key-value memories the AI can read and manage
    var memories: [String: String] = [:]

    // MARK: - Advanced Settings

    /// Auto-reconnect on connection drop
    var autoReconnect: Bool = true

    /// Show live transcripts in UI
    var showTranscripts: Bool = true

    /// Video frame rate for Gemini Live (frames per second)
    var geminiVideoFPS: Int = 1

    // MARK: - Computed Properties

    /// Whether OpenClaw is configured (has URL and token)
    var isOpenClawConfigured: Bool {
        !openClawGatewayURL.isEmpty && !openClawAuthToken.isEmpty
    }

    /// Whether Gemini is configured (has API key)
    var isGeminiConfigured: Bool {
        !geminiAPIKey.isEmpty
    }

    /// Whether Yandex Cloud is configured (key + folder)
    var isYandexConfigured: Bool {
        !yandexAPIKey.isEmpty && !yandexFolderID.isEmpty
    }

    /// Whether OpenAI is configured (has API key)
    var isOpenAIConfigured: Bool {
        !openAIAPIKey.isEmpty && !openAIBaseURL.isEmpty
    }

    /// Whether the local Gemma backend is ready (model downloaded)
    var isLocalGemmaConfigured: Bool {
        localGemmaModelReady
    }

    /// Whether the currently selected backend is configured
    var isCurrentBackendConfigured: Bool {
        switch aiBackend {
        case .openClaw: return isOpenClawConfigured
        case .geminiLive: return isGeminiConfigured
        case .openAI: return isOpenAIConfigured
        case .appleFoundation: return true   // OS-managed; availability checked at connect
        case .localGemma: return isLocalGemmaConfigured
        case .yandex: return isYandexConfigured
        }
    }

    /// Backend label for the UI. For the local backend, reflects the *actually selected* MLX model
    /// (Qwen / SmolVLM / FastVLM / …) instead of a fixed name, so the main-screen pill is accurate.
    var backendDisplayName: String {
        guard aiBackend == .localGemma else { return aiBackend.displayName }
        return "Local · \(GemmaLocalModel.from(modelId: localGemmaModelId).displayName)"
    }
}
