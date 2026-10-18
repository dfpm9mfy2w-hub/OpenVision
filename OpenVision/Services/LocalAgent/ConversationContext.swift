// OpenVision - ConversationContext.swift
// A small, bounded record of the current conversation so follow-up questions work
// ("what's the capital of France?" → "what's its population?").
//
// Used by the stateless prompt-based backends (Local Gemma, OpenAI). Cloud backends that keep
// their own server-side context (OpenClaw, Gemini Live) ignore this. Apple Foundation keeps
// context natively via a reused LanguageModelSession, so it doesn't read this either.

import Foundation

@MainActor
final class ConversationContext {
    static let shared = ConversationContext()

    struct Turn: Codable { let role: String; let content: String }   // role: "user" | "assistant"

    /// Recent exchanges, persisted so a conversation survives app restarts (cleared by
    /// "новый разговор" or an explicit `clear()`).
    private var stored: [Turn] = [] {
        didSet { save() }
    }

    /// The short window local models get — bounded so they stay within their memory/context budget.
    var turns: [Turn] { Array(stored.suffix(maxMessages)) }

    /// Everything kept, for cloud models with a large context (OpenAI).
    var allTurns: [Turn] { stored }

    private let maxMessages = 8
    private let maxStoredMessages = 24
    private static let defaultsKey = "ConversationContext.turns"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Turn].self, from: data) {
            stored = saved
        }
    }

    func record(user: String, assistant: String) {
        append(role: "user", content: user)
        append(role: "assistant", content: assistant)
    }

    func clear() { stored.removeAll() }

    /// Resume a past conversation from History: reload its recent exchanges as live context so
    /// follow-up questions pick up where that conversation left off.
    func seed(from conversation: Conversation) {
        var seeded: [Turn] = []
        for message in conversation.messages.suffix(maxStoredMessages) {
            switch message.role {
            case .user: seeded.append(Turn(role: "user", content: message.content))
            case .assistant: seeded.append(Turn(role: "assistant", content: message.content))
            default: break
            }
        }
        stored = seeded
    }

    private func append(role: String, content: String) {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var updated = stored
        updated.append(Turn(role: role, content: clean))
        if updated.count > maxStoredMessages { updated.removeFirst(updated.count - maxStoredMessages) }
        stored = updated
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
