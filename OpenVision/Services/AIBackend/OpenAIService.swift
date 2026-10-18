// OpenVision - OpenAIService.swift
// Cloud backend for the OpenAI Chat Completions API (and any OpenAI-compatible endpoint).
//
// Simple request/response (non-streaming) — reliable for validating the cloud command + vision
// path. Supports text and images (base64 data URL). The reply is delivered via `onAgentMessage`,
// matching the other backends so VoiceAgentView can wire it up the same way.

import Foundation
import UIKit

@MainActor
final class OpenAIService: ObservableObject {

    static let shared = OpenAIService()

    /// Called with the assistant's reply text (spoken via TTS by VoiceAgentView).
    var onAgentMessage: ((String) -> Void)?
    /// Called when processing starts/stops (drives the thinking/listening state).
    var onProcessingChanged: ((Bool) -> Void)?

    @Published private(set) var isConnected = false

    private var settings: AppSettings { SettingsManager.shared.settings }

    private init() {}

    /// Lightweight "connect": stateless HTTP, so just validate config.
    func connect() async throws {
        _ = try endpoint()
        isConnected = true
    }

    /// Where Chat Completions requests go: OpenAI (or a compatible endpoint), or Yandex Cloud
    /// AI Studio when that backend is selected. Same request format, different auth and models.
    private struct Endpoint {
        let chatURL: URL
        let headers: [String: String]
        let textModel: String
        let visionModel: String
        /// api.openai.com wants max_completion_tokens; others keep max_tokens.
        let usesCompletionTokens: Bool
        let isYandex: Bool
    }

    private func endpoint() throws -> Endpoint {
        if settings.aiBackend == .yandex {
            guard settings.isYandexConfigured,
                  let url = URL(string: YandexCloud.baseURL + "/chat/completions") else {
                throw OpenAIError.notConfigured
            }
            return Endpoint(chatURL: url,
                            headers: YandexCloud.headers(settings),
                            textModel: YandexCloud.modelURI(settings.yandexTextModel, settings),
                            visionModel: YandexCloud.modelURI(settings.yandexVisionModel, settings),
                            usesCompletionTokens: false,
                            isYandex: true)
        }
        guard settings.isOpenAIConfigured,
              let url = URL(string: "\(settings.openAIBaseURL)/chat/completions") else {
            throw OpenAIError.notConfigured
        }
        return Endpoint(chatURL: url,
                        headers: ["Authorization": "Bearer \(settings.openAIAPIKey)"],
                        textModel: settings.openAIModel,
                        visionModel: settings.openAIModel,
                        usesCompletionTokens: URL(string: settings.openAIBaseURL)?.host?.hasSuffix("openai.com") ?? false,
                        isYandex: false)
    }

    /// Send a prompt (optionally with an image) and deliver the reply via `onAgentMessage`.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        try await sendMessage(text, images: imageData.map { [$0] } ?? [])
    }

    /// Send a prompt with several JPEG frames (oldest first) so the model sees what changed over
    /// the last seconds, not a single still.
    func sendMessage(_ text: String, images: [Data]) async throws {
        let endpoint = try endpoint()
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)

        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        // Build the user content: plain string for text-only, or the multimodal array with one
        // image_url data URL per attached frame.
        let userContent: Any
        if !images.isEmpty {
            var parts: [[String: Any]] = [["type": "text", "text": text.isEmpty ? "Describe what you see." : text]]
            for imageData in images {
                let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": dataURL]])
            }
            userContent = parts
        } else {
            userContent = text
        }

        var messages: [[String: Any]] = []
        let system = systemPrompt()
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        // Document-focus mode: while the user is working with a document, its most relevant
        // excerpts ride along on EVERY request — deterministic grounding, no tool-call judgment.
        if let docContext = DocumentFocus.shared.contextForQuery(text) {
            messages.append(["role": "system", "content": docContext])
        }
        // Prior turns (persisted across launches) so follow-ups and earlier context work.
        for turn in ConversationContext.shared.allTurns {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": userContent])

        // Agentic web-search tool: the model calls it for current info, we run it, feed the result
        // back, and it can refine or answer — an iterative loop (OpenGlasses' cloud pattern).
        let webSearchTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current, real-time information — news, weather, prices, sports scores, recent events, or anything you're not certain of. Use it whenever the user asks about something current.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "The search query"]],
                    "required": ["query"]
                ]
            ]
        ]

        // Long-term memory: lasting facts about the user, kept in Settings → Memories and fed back
        // into every system prompt.
        let rememberTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "remember",
                "description": "Save a lasting fact about the user (name, preferences, people, places, plans) so you know it in future conversations. Use it when the user asks you to remember something or shares a stable personal fact.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string", "description": "Short label, e.g. 'имя' or 'любимый кофе'"],
                        "value": ["type": "string", "description": "The fact itself"]
                    ],
                    "required": ["key", "value"]
                ]
            ]
        ]
        let forgetTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "forget",
                "description": "Delete a saved fact about the user when they ask you to forget it or it is no longer true.",
                "parameters": [
                    "type": "object",
                    "properties": ["key": ["type": "string", "description": "The label of the fact to delete"]],
                    "required": ["key"]
                ]
            ]
        ]

        // Web search + memory + on-device productivity tools (timers, reminders, calendar, notes…).
        let tools = [webSearchTool, rememberTool, forgetTool] + NativeToolRegistry.shared.openAISpecs

        // Photos go to the image-capable model (Yandex has a separate one).
        let model = images.isEmpty ? endpoint.textModel : endpoint.visionModel
        // Yandex's OpenAI-compatible layer may not accept tools for every model; if it refuses,
        // answer without them rather than not at all.
        var useTools = true

        let maxIterations = 4
        for _ in 0..<maxIterations {
            var body: [String: Any] = [
                "model": model,
                "messages": messages
            ]
            if useTools { body["tools"] = tools }
            // OpenAI's current models take `max_completion_tokens` (newer ones reject `max_tokens`
            // and spend part of the budget on reasoning); other endpoints keep `max_tokens`.
            if endpoint.usesCompletionTokens {
                body["max_completion_tokens"] = 1500
            } else {
                body["max_tokens"] = endpoint.isYandex ? 1000 : 400
            }
            var request = URLRequest(url: endpoint.chatURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (header, value) in endpoint.headers {
                request.setValue(value, forHTTPHeaderField: header)
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60

            let (data, response) = try await Self.dataWithRetry(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenAIError.noResponse }
            guard (200...299).contains(http.statusCode) else {
                let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
                if endpoint.isYandex && useTools && http.statusCode == 400 {
                    NSLog("[OpenAI] Yandex refused tools (%@) — retrying without them", detail)
                    useTools = false
                    continue
                }
                NSLog("[OpenAI] request failed: %@", detail)
                throw OpenAIError.api(detail)
            }
            guard let message = Self.firstMessage(from: data) else { throw OpenAIError.emptyReply }

            // Tool calls → execute (web_search or a native tool), feed results back, loop.
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                messages.append(message)   // the assistant turn carrying tool_calls
                for call in toolCalls {
                    let id = call["id"] as? String ?? ""
                    let fn = call["function"] as? [String: Any]
                    let toolName = fn?["name"] as? String ?? ""
                    let argsStr = fn?["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]

                    let result: String
                    if toolName == "web_search" {
                        let query = (args["query"] as? String) ?? ""
                        NSLog("[OpenAI] web_search (%d chars)", query.count)
                        let r = await WebSearchService.search(query)
                        result = r.isEmpty ? "No results found for \"\(query)\"." : r
                    } else if toolName == "remember" {
                        let key = ((args["key"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = ((args["value"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if key.isEmpty || value.isEmpty {
                            result = "Nothing saved: key and value are required."
                        } else {
                            SettingsManager.shared.setMemory(key: key, value: value)
                            NSLog("[OpenAI] remembered a fact")
                            result = "Saved."
                        }
                    } else if toolName == "forget" {
                        let key = ((args["key"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if SettingsManager.shared.settings.memories[key] != nil {
                            SettingsManager.shared.deleteMemory(key: key)
                            result = "Deleted."
                        } else {
                            result = "No saved fact with that label. Saved labels: \(SettingsManager.shared.settings.memories.keys.sorted().joined(separator: ", "))"
                        }
                    } else {
                        NSLog("[OpenAI] native tool: %@", toolName)
                        result = await NativeToolRegistry.shared.execute(name: toolName, args: args)
                    }
                    messages.append(["role": "tool", "tool_call_id": id, "content": result])
                }
                continue
            }

            // No tool call → final spoken answer.
            guard let reply = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw OpenAIError.emptyReply
            }
            ConversationContext.shared.record(user: text, assistant: reply)
            onAgentMessage?(reply)
            return
        }
        throw OpenAIError.api("search loop didn't converge")
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        // Who the assistant is, how replies sound (they're spoken aloud), tools, then what it
        // knows about the user, then the user's custom instructions.
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var parts: [String] = []
        let persona = settings.assistantPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(persona.isEmpty ? "You are a helpful voice assistant for smart glasses." : persona)
        parts.append("Your replies are spoken aloud through the glasses: answer in 1-3 short sentences, with no lists, tables, markdown, emoji or links unless the user asks for detail. Write numbers, times and units the way they are naturally said. When describing an image, start with the main thing and skip phrases like 'in the image I see'. If the user asks about current or real-time information (weather, news, prices, scores, opening hours) or anything you're not certain of, call the web_search tool and answer from its results — never say you can't access real-time data. When the user asks you to remember something, or tells you a lasting fact about themselves, call remember; call forget when asked to forget.")
        parts.append("You can also handle productivity hands-free by calling the matching tool: set_timer, start_pomodoro, create_reminder, calendar (read/add events), note (save/search notes auto-tagged with place and time), copy_to_clipboard, and search_docs (search the user's imported manuals/recipes/guides — use it whenever they ask about their documents, and answer only from what it returns). For a specific time of day (e.g. '6pm', '9:30am') pass the tool's hour (24-hour) and minute, plus day_offset (0=today, 1=tomorrow) — let the tool do the date math. Use minutes_from_now only for 'in N minutes'. The current time is \(today).")
        parts.append("After a tool runs, briefly confirm what you did in one sentence.")
        let memories = settings.memories
        if !memories.isEmpty {
            let facts = memories.keys.sorted().map { "- \($0): \(memories[$0] ?? "")" }.joined(separator: "\n")
            parts.append("What you know about the user (saved facts):\n\(facts)")
        }
        let custom = settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Response parsing

    /// Chat Completions can drop a keep-alive connection between the multiple round-trips of a
    /// tool-calling loop (URLError -1005 "network connection lost", or a transient timeout). These
    /// are almost always recoverable, so retry once on a fresh connection before surfacing an error.
    private static func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where
            [.networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
            NSLog("[OpenAI] transient network error (%d) — retrying once", error.errorCode)
            try? await Task.sleep(nanoseconds: 600_000_000)
            return try await URLSession.shared.data(for: request)
        }
    }

    /// The full assistant message dict (content and/or tool_calls) from a Chat Completions response.
    private static func firstMessage(from data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    enum OpenAIError: LocalizedError {
        // notConfigured covers both OpenAI and Yandex Cloud.
        case notConfigured, badURL, noResponse, emptyReply, api(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "The AI backend isn't configured. Add the key in Settings → AI Backend."
            case .badURL: return "The OpenAI base URL is invalid."
            case .noResponse: return "No response from OpenAI."
            case .emptyReply: return "OpenAI returned an empty reply."
            case .api(let detail): return "OpenAI error: \(detail)"
            }
        }
    }
}

// MARK: - Yandex Cloud

/// Yandex Cloud AI Studio + SpeechKit connection details, shared by chat, web search and voice.
enum YandexCloud {
    /// OpenAI-compatible AI Studio endpoint (Chat Completions and Responses).
    static let baseURL = "https://ai.api.cloud.yandex.net/v1"

    /// SpeechKit REST synthesis (API v1: plain form request, MP3 out).
    static let ttsURL = "https://tts.api.cloud.yandex.net/speech/v1/tts:synthesize"

    /// API-key auth, the folder that is billed, and server-side request logging switched off
    /// (Yandex keeps request logs by default; this header opts out).
    @MainActor
    static func headers(_ settings: AppSettings) -> [String: String] {
        [
            "Authorization": "Api-Key \(settings.yandexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            "OpenAI-Project": settings.yandexFolderID.trimmingCharacters(in: .whitespacesAndNewlines),
            "x-data-logging-enabled": "false"
        ]
    }

    /// "aliceai-llm" → "gpt://<folder>/aliceai-llm" (a full gpt:// URI is used as is).
    @MainActor
    static func modelURI(_ model: String, _ settings: AppSettings) -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("gpt://") { return model }
        return "gpt://\(settings.yandexFolderID.trimmingCharacters(in: .whitespacesAndNewlines))/\(model)"
    }
}
