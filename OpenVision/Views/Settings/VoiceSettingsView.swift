// OpenVision - VoiceSettingsView.swift
// Voice control settings: wake word, conversation timeout

import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - Computed Properties

    private var selectedVoiceName: String {
        guard let identifier = settingsManager.settings.selectedVoiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier) else {
            return "System Default"
        }
        return voice.name
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Wake Word Section
            Section {
                Toggle(isOn: $settingsManager.settings.wakeWordEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Wake Word")
                        Text("Only listen after wake phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if settingsManager.settings.wakeWordEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wake Phrase")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Ok Vision", text: $settingsManager.settings.wakeWord)
                            .autocorrectionDisabled()
                    }

                    // Which language the recognizer listens in (follows the phrase / iPhone language).
                    LabeledContent("Recognition language",
                                   value: VoiceCommandService.shared.recognitionLocaleID == "ru-RU" ? "Русский" : "English")
                }
            } header: {
                Text("Wake Word")
            } footer: {
                if settingsManager.settings.wakeWordEnabled {
                    Text("Say \"\(settingsManager.settings.wakeWord)\" to activate the assistant. This protects your privacy by only listening after the wake phrase.")
                } else {
                    Text("Wake word is disabled. The app will always be listening when active (Gemini Live mode behavior).")
                }
            }

            // Microphone Section
            Section {
                Toggle(isOn: $settingsManager.settings.preferGlassesMic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Glasses Mic")
                        Text("Listen through the glasses when worn")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("When on, voice input uses the glasses' Bluetooth microphone for true hands-free use, and falls back to the phone mic automatically when the glasses aren't the audio device. Uses more battery. Turn off to always use the phone mic.")
            }

            // Conversation Section
            Section {
                Picker("Auto-End Timeout", selection: $settingsManager.settings.conversationTimeout) {
                    Text("15 seconds").tag(TimeInterval(15))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("Never").tag(TimeInterval(0))
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("Automatically end the conversation after this period of silence. With Never, the assistant stays until you dismiss it (\"Дубина, можешь идти\", \"Пока, Дубина\").")
            }

            // TTS Voice Section
            Section {
                Picker("Speech Engine", selection: $settingsManager.settings.ttsEngine) {
                    ForEach(TTSEngineType.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if settingsManager.settings.ttsEngine == .appleSystem {
                    NavigationLink {
                        VoiceSelectionView()
                    } label: {
                        HStack {
                            Text("Apple Voice")
                            Spacer()
                            Text(selectedVoiceName).foregroundColor(.secondary)
                        }
                    }
                } else if settingsManager.settings.ttsEngine == .yandex {
                    Picker("Голос Яндекса", selection: $settingsManager.settings.yandexVoice) {
                        Text("Ермил").tag("ermil")
                        Text("Филипп").tag("filipp")
                        Text("Захар").tag("zahar")
                        Text("Мади").tag("madi_ru")
                    }
                    if ["ermil", "zahar"].contains(settingsManager.settings.yandexVoice) {
                        Picker("Интонация", selection: $settingsManager.settings.yandexVoiceRole) {
                            Text("Нейтральная").tag("neutral")
                            Text("Доброжелательная").tag("good")
                        }
                    }
                    Picker("Скорость", selection: $settingsManager.settings.yandexVoiceSpeed) {
                        Text("Медленнее").tag(0.9)
                        Text("Обычная").tag(1.0)
                        Text("Быстрее").tag(1.1)
                    }
                    Button {
                        TTSService.shared.speak("Добрый день, сэр. Дубина к вашим услугам.")
                    } label: {
                        Label("Проверить голос", systemImage: "play.circle")
                    }
                    .disabled(!settingsManager.settings.isYandexConfigured)
                } else if settingsManager.settings.ttsEngine == .openAI {
                    Picker("OpenAI Voice", selection: $settingsManager.settings.openAITTSVoice) {
                        ForEach(Self.openAIVoices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speaking Style")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("How the voice should sound", text: $settingsManager.settings.openAITTSInstructions, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    Button {
                        TTSService.shared.speak("Добрый день, сэр. Дубина к вашим услугам.")
                    } label: {
                        Label("Test Voice", systemImage: "play.circle")
                    }
                    .disabled(settingsManager.settings.openAIAPIKey.isEmpty)
                } else {
                    Picker("Kokoro Voice", selection: $settingsManager.settings.kokoroVoice) {
                        ForEach(KokoroTTSService.voices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    NavigationLink {
                        KokoroSettingsView()
                    } label: {
                        HStack {
                            Label("Kokoro Model", systemImage: "waveform")
                            Spacer()
                            Text(KokoroTTSService.shared.isModelReady ? "Ready" : "Download")
                                .font(.caption)
                                .foregroundColor(KokoroTTSService.shared.isModelReady ? .green : .orange)
                        }
                    }
                }
            } header: {
                Text("Output Voice")
            } footer: {
                if settingsManager.settings.ttsEngine == .yandex {
                    Text(settingsManager.settings.isYandexConfigured
                         ? "Естественный русский голос Яндекс SpeechKit. Нужен интернет; при сбое включится системный голос."
                         : "Сначала укажите ключ и ID каталога в AI Backend → Яндекс Облако. Пока используется системный голос.")
                } else if settingsManager.settings.ttsEngine == .openAI {
                    Text(settingsManager.settings.openAIAPIKey.isEmpty
                         ? "Add an OpenAI API key under AI Backend → OpenAI first. Until then the system voice is used."
                         : "Natural cloud voice (gpt-4o-mini-tts) using your OpenAI key. Needs internet; if it fails, the system voice takes over.")
                } else if settingsManager.settings.ttsEngine == .kokoro {
                    Text("Kokoro is a natural, on-device neural voice — private and offline. Download its model (~600 MB) under Kokoro Model, then it runs entirely on-device.")
                } else {
                    Text("Apple's built-in system voice. For higher quality, download a Premium/Enhanced voice in iOS Settings → Accessibility → Spoken Content.")
                }
            }

            // Feedback Section
            Section {
                Toggle(isOn: $settingsManager.settings.playActivationSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activation Sound")
                        Text("Play chime on wake word")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Feedback")
            }

            // Info Section
            Section {
                HStack {
                    Text("Supported Phrases")
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(samplePhrases, id: \.self) { phrase in
                        HStack {
                            Image(systemName: "quote.bubble")
                                .foregroundColor(.secondary)
                            Text(phrase)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Examples")
            } footer: {
                Text("The wake word detection is flexible and will recognize variations like \"OK Vision\" or \"Okay Vision\".")
            }
        }
        .navigationTitle("Voice Control")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Voices offered by gpt-4o-mini-tts.
    private static let openAIVoices = ["onyx", "ash", "echo", "fable", "cedar", "verse", "ballad",
                                       "alloy", "sage", "coral", "marin", "nova", "shimmer"]

    // MARK: - Sample Phrases

    private var samplePhrases: [String] {
        let wake = settingsManager.settings.wakeWord
        return [
            "\(wake), what's the weather?",
            "\(wake), take a photo",
            "\(wake), remind me to...",
            "\(wake), search for..."
        ]
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
