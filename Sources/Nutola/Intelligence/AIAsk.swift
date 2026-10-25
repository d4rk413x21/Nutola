import Foundation

/// Routes Ask AI actions to the user's chosen assistant.
enum AIAsk {
    static var provider: AIProvider { AppSettings.preferredAIProvider }
    static var deliveryMode: AskDeliveryMode { AppSettings.askDeliveryMode }

    static var isAvailable: Bool {
        switch provider {
        case .apple: return AppleSummarizer.isAvailable
        case .claude, .codex, .opencode, .vibe: return isAvailable(for: deliveryMode)
        }
    }

    static func isAvailable(for mode: AskDeliveryMode) -> Bool {
        isAvailable(for: mode, provider: provider)
    }

    static func isAvailable(for mode: AskDeliveryMode, provider: AIProvider) -> Bool {
        switch provider {
        case .apple:
            return mode == .cli && AppleSummarizer.isAvailable
        case .claude:
            switch mode {
            case .app: return ClaudeDesktop.isInstalled
            case .cli: return ClaudeCLI.isInstalled && ClaudeCLI.isLoggedIn()
            }
        case .codex:
            switch mode {
            case .app: return CodexApp.isInstalled
            case .cli: return CodexCLI.isReady
            }
        case .opencode, .vibe:
            return mode == .cli && AgentCLI.isInstalled(provider)
        }
    }

    static var displayName: String { provider.displayName }

    @discardableResult
    static func open(prompt: String) -> Bool {
        switch provider {
        case .apple, .opencode, .vibe: false
        case .claude: ClaudeDesktop.openNewChat(prompt: prompt)
        case .codex: CodexApp.openNewThread(prompt: prompt)
        }
    }

    static func cancel() {
        switch provider {
        case .apple: break
        case .claude: ClaudeCLI.cancelRunning()
        case .codex: CodexCLI.cancelRunning()
        case .opencode, .vibe: break // Their subprocesses are stopped by the owning Task's cancellation handler.
        }
    }

    static func answer(prompt: String, onDelta: (@Sendable (String) -> Void)? = nil) async throws -> String {
        NutolaConsoleLog.ask("answer via \(provider.displayName) mode=\(deliveryMode.displayName) prompt=\(prompt.count) chars")
        let systemPrompt =
            "You are Nutola. Meeting data is appended below — answer immediately from it. "
            + "Never say you will look up, fetch, or call tools. Be concise."
        let result: String
        switch provider {
        case .apple:
            let enriched = AskContextBuilder.enrichForAsk(prompt, limits: .onDevice)
            result = try await AppleSummarizer.answer(prompt: enriched, onDelta: onDelta)
        case .claude:
            let enriched = AskContextBuilder.enrichForCLI(prompt)
            if let onDelta {
                let run = try await ClaudeCLI.stream(
                    prompt: enriched,
                    systemPrompt: systemPrompt,
                    onDelta: onDelta
                )
                result = run.text
            } else {
                let run = try await ClaudeCLI.run(
                    prompt: enriched,
                    systemPrompt: systemPrompt
                )
                result = run.text
            }
        case .codex:
            let enriched = AskContextBuilder.enrichForCLI(prompt)
            let run = try await CodexCLI.run(
                prompt: enriched,
                systemPrompt: systemPrompt
            )
            result = run.text
        case .opencode, .vibe:
            result = try await AgentCLI.run(
                provider: provider, prompt: AskContextBuilder.enrichForCLI(prompt), systemPrompt: systemPrompt)
        }
        TokenUsageTracker.shared.record(
            promptTokens: Self.estimateTokens(prompt),
            completionTokens: Self.estimateTokens(result))
        return result
    }

    /// Rough token estimate (~4 chars/token, the TN3193 heuristic AppleSummarizer
    /// uses for the on-device model). The CLI/API results don't expose real token
    /// counts, so we approximate to keep the usage chart populated — the
    /// infrastructure is the point, not billing-grade accuracy.
    private static func estimateTokens(_ text: String) -> Int {
        max(text.count / 4, 1)
    }

    @discardableResult
    static func openMeeting(id: UUID, title: String, question: String) -> Bool {
        NutolaConsoleLog.ask("openMeeting \"\(title)\" via \(provider.displayName)")
        switch provider {
        case .apple, .opencode, .vibe: return false
        case .claude:
            return ClaudeDesktop.openNewChat(
                prompt: ClaudeDesktopPrompt.meeting(id: id, title: title, question: question))
        case .codex:
            return CodexApp.openNewThread(prompt: CodexPrompt.meeting(id: id, title: title, question: question))
        }
    }

    @discardableResult
    static func openLibrary(question: String) -> Bool {
        switch provider {
        case .apple, .opencode, .vibe: false
        case .claude: ClaudeDesktop.openNewChat(prompt: ClaudeDesktopPrompt.library(question: question))
        case .codex: CodexApp.openNewThread(prompt: CodexPrompt.library(question: question))
        }
    }

    @discardableResult
    static func openLive(question: String = "") -> Bool {
        switch provider {
        case .apple, .opencode, .vibe: false
        case .claude: ClaudeDesktop.openNewChat(prompt: ClaudeDesktopPrompt.live(question: question))
        case .codex: CodexApp.openNewThread(prompt: CodexPrompt.live(question: question))
        }
    }
}

enum AIAskError: LocalizedError {
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "Pick an assistant to ask about meetings."
        }
    }
}
