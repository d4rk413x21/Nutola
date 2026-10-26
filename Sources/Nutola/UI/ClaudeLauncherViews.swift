import AppKit
import SwiftUI

struct MeetingLauncherView: View {
    let meeting: Meeting
    var initialQuestion: String?

    private var suggestions: [String] {
        MeetingAISuggestions.forMeeting(meeting)
    }
    var body: some View {
        AILauncherView(
            headline: "Ask about this meeting",
            subtitle: "Summarize, pull action items, or draft a follow-up.",
            suggestions: suggestions,
            contextMeeting: meeting,
            initialQuestion: initialQuestion,
            promptBuilder: { question in
                switch AppSettings.preferredAIProvider {
                case .apple, .opencode, .vibe:
                    ClaudeDesktopPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                case .claude:
                    ClaudeDesktopPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                case .codex:
                    CodexPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                }
            }
        )
    }
}

struct LibraryLauncherView: View {
    @EnvironmentObject private var app: AppState

    private var recentMeetings: [Meeting] {
        app.store.meetings
            .filter { $0.state == .ready }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        AILauncherView(
            headline: "Hi \(UserGreeting.firstName), ask anything",
            subtitle: "Ask questions across all your recorded meetings.",
            suggestions: MeetingAISuggestions.library,
            recentMeetings: recentMeetings,
            promptBuilder: { question in
                switch AppSettings.preferredAIProvider {
                case .apple, .claude, .opencode, .vibe:
                    ClaudeDesktopPrompt.library(question: question)
                case .codex:
                    CodexPrompt.library(question: question)
                }
            },
            meetingPromptBuilder: { meeting, question in
                switch AppSettings.preferredAIProvider {
                case .apple, .claude, .opencode, .vibe:
                    ClaudeDesktopPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                case .codex:
                    CodexPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                }
            }
        )
        .navigationTitle("Ask")
    }
}

/// Shared launcher: hero compose field, recents, and recipe chips for the user's assistant.
struct AILauncherView: View {
    let headline: String
    let subtitle: String?
    let suggestions: [String]
    var recentMeetings: [Meeting] = []
    var contextMeeting: Meeting?
    /// Pre-seeds and auto-submits a question on first appear (used by the
    /// floating panel's suggestion chips to route through the in-app CLI
    /// streaming UI instead of always opening the external app).
    var initialQuestion: String?
    let promptBuilder: (String) -> String
    var meetingPromptBuilder: ((Meeting, String) -> String)?

    @EnvironmentObject private var app: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.preferredAIProvider) private var preferredAIProvider: AIProvider = .apple
    @AppStorage(SettingsKey.askDeliveryMode) private var askDeliveryMode: AskDeliveryMode = .cli
    @AppStorage(SettingsKey.askMaxTurns) private var askMaxTurns = 5
    @State private var input = ""
    @State private var available = false
    @State private var deliveryModeAvailability: [AskDeliveryMode: Bool] = [:]
    @State private var launchFailed = false
    @State private var isAnswering = false
    @State private var messages: [AskChatMessage] = []
    @State private var loadingMessageID: UUID?
    @State private var answerTask: Task<Void, Never>?
    @State private var didSubmitInitialQuestion = false
    @State private var didSaveRecipe = false
    @FocusState private var composeFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor
    @StateObject private var recipeStore = RecipeStore()

    private var isConversationMode: Bool {
        !messages.isEmpty
    }

    private var effectiveMode: AskDeliveryMode {
        preferredAIProvider.supportsApp ? askDeliveryMode : .cli
    }

    var body: some View {
        Group {
            if isConversationMode {
                conversationBody
            } else {
                launcherBody
            }
        }
        .background(Theme.surface(scheme))
        .onAppear {
            refreshAvailability()
            seedRecipesFromSuggestionsIfNeeded()
            submitInitialQuestionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nutolaCLIAvailabilityChanged)) { _ in
            refreshAvailability()
        }
        .onChange(of: preferredAIProvider) {
            refreshAvailability()
            if isAnswering { stopAnswering() }
        }
        .onChange(of: askDeliveryMode) {
            refreshAvailability()
            if isAnswering { stopAnswering() }
        }
    }

    private var launcherBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                composeHero

                if showsLongTranscriptHint {
                    longTranscriptHint
                }

                if !recentMeetings.isEmpty, meetingPromptBuilder != nil {
                    recentsSection
                }

                if !recipeStore.all().isEmpty {
                    recipesSection
                }
                footerNotices
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 44)
            .contentColumn()
        }
    }

    private var conversationBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    conversationHeader
                    chatSection
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)
                .contentColumn()
            }

            VStack(alignment: .leading, spacing: 12) {
                composeHero

                if showsLongTranscriptHint {
                    longTranscriptHint
                }

                footerNotices
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .contentColumn()
        }
    }

    private var conversationHeader: some View {
        HStack(alignment: .center) {
            Text(headline)
                .font(.nutola(20, .bold))
                .foregroundStyle(Theme.heading(scheme))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("New conversation", action: newConversation)
                .font(.nutola(12, .medium))
                .buttonStyle(.plain)
                .foregroundStyle(actionColor)
            closeButton
        }
    }

    private func newConversation() {
        stopAnswering()
        messages = []
        input = ""
        launchFailed = false
        composeFocused = true
    }

    private func refreshAvailability() {
        let provider = preferredAIProvider
        let mode = effectiveMode
        Task.detached {
            var byMode: [AskDeliveryMode: Bool] = [:]
            for deliveryMode in AskDeliveryMode.allCases {
                byMode[deliveryMode] = AIAsk.isAvailable(for: deliveryMode, provider: provider)
            }
            let availability = byMode
            await MainActor.run {
                deliveryModeAvailability = availability
                available = availability[mode] ?? false
            }
        }
    }

    private var contextTranscriptChars: Int {
        guard let contextMeeting else { return 0 }
        return app.store.transcript(for: contextMeeting.id)
            .reduce(0) { $0 + $1.text.count }
    }

    private var showsLongTranscriptHint: Bool {
        askDeliveryMode == .cli
            && contextTranscriptChars > 20_000
            && askMaxTurns < 8
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.nutola(26, .bold))
                    .foregroundStyle(Theme.heading(scheme))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.nutola(13))
                        .foregroundStyle(Theme.secondary(scheme))
                }
            }
            Spacer(minLength: 8)
            closeButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.tertiary(scheme))
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close")
    }

    private var composeHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.nutola(15))
                .lineLimit(3...8)
                .focused($composeFocused)
                .disabled(!available || isAnswering)
                .onSubmit(launchTyped)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

            HStack(alignment: .center, spacing: 10) {
                providerBadge
                saveAsRecipeButton
                Spacer(minLength: 8)
                submitButton
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(composeBorder, lineWidth: composeFocused ? 1.5 : 1)
        }
        .shadow(
            color: actionColor.opacity(composeFocused && available ? 0.18 : 0),
            radius: composeFocused ? 16 : 0,
            y: composeFocused ? 4 : 0
        )
        .animation(.easeOut(duration: 0.18), value: composeFocused)
    }

    private var composeBorder: some ShapeStyle {
        if composeFocused, available {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [actionColor.opacity(0.65), Theme.blueberry(scheme).opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.14 : 0.1))
    }

    @ViewBuilder
    private var providerBadge: some View {
        Menu {
            Section("Assistant") {
                ForEach(AIProvider.askChoices) { provider in
                    Button {
                        preferredAIProvider = provider
                    } label: {
                        if preferredAIProvider == provider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            }
            Section("How to answer") {
                ForEach(preferredAIProvider.deliveryModes) { mode in
                    Button {
                        askDeliveryMode = mode
                    } label: {
                        if effectiveMode == mode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                    .disabled(!(deliveryModeAvailability[mode] ?? false))
                }
            }
            .disabled(preferredAIProvider == .apple)

            if askDeliveryMode == .cli, preferredAIProvider != .apple {
                Section("Context") {
                    Button("More tool rounds (\(askMaxTurns) → \(min(askMaxTurns + 2, 15)))") {
                        askMaxTurns = min(askMaxTurns + 2, 15)
                    }
                    .disabled(askMaxTurns >= 15)
                    Button("Fewer tool rounds (\(askMaxTurns) → \(max(askMaxTurns - 2, 3)))") {
                        askMaxTurns = max(askMaxTurns - 2, 3)
                    }
                    .disabled(askMaxTurns <= 3)
                    Button("Open Intelligence settings…") { openSettings() }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: badgeIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(badgeLabel)
                    .font(.nutola(11, .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(Theme.secondary(scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change assistant or how questions are answered")
        .accessibilityLabel("Change assistant or how questions are answered")
    }

    private var badgeIcon: String {
        switch preferredAIProvider {
        case .apple: "apple.intelligence"
        case .opencode, .vibe: "terminal"
        case .codex where askDeliveryMode == .cli: "terminal"
        case .claude where askDeliveryMode == .cli: "terminal"
        default: "sparkles"
        }
    }

    private var badgeLabel: String {
        switch preferredAIProvider {
        case .apple:
            return "Apple Intelligence"
        case .claude, .codex, .opencode, .vibe:
            if effectiveMode == .cli {
                return "\(preferredAIProvider.displayName) · CLI"
            }
            return preferredAIProvider.displayName
        }
    }

    private var submitButton: some View {
        Group {
            if isAnswering {
                Button(action: stopAnswering) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(actionColor))
                }
                .buttonStyle(.plain)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                let canSubmit = available && !input.trimmingCharacters(in: .whitespaces).isEmpty
                Button(action: launchTyped) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(canSubmit ? actionColor : Color.secondary.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help(submitHelp)
                .accessibilityLabel("Send question")
            }
        }
    }

    private var submitHelp: String {
        switch preferredAIProvider {
        case .apple: "Answer with Apple Intelligence"
        case .claude, .codex, .opencode, .vibe:
            switch effectiveMode {
            case .cli: "Answer with \(preferredAIProvider.displayName) CLI"
            case .app: "Open in \(preferredAIProvider.displayName)"
            }
        }
    }

    /// Small "Save as recipe" affordance next to the submit button. Only shown
    /// when the user has typed something they could save; the checkmark flips
    /// briefly after a save to confirm. Kept deliberately understated so it
    /// doesn't compete with the submit arrow.
    private var saveAsRecipeButton: some View {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let canSave = !trimmed.isEmpty && !isAnswering
        return Button(action: saveCurrentInputAsRecipe) {
            Image(systemName: didSaveRecipe ? "checkmark" : "bookmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(didSaveRecipe ? actionColor : Theme.secondary(scheme))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0)
        .help("Save as recipe")
        .accessibilityLabel("Save as recipe")
        .animation(.easeOut(duration: 0.18), value: didSaveRecipe)
    }

    private var chatSection: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(messages) { message in
                AskChatBubble(message: message)
            }
        }
    }

    private var longTranscriptHint: some View {
        HStack(spacing: 6) {
            Text("This meeting has a long transcript — increase context rounds for better answers.")
                .font(.nutola(11))
                .foregroundStyle(Theme.tertiary(scheme))
            Button("Settings") { openSettings() }
                .font(.nutola(11, .medium))
                .buttonStyle(.plain)
                .foregroundStyle(actionColor)
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recents")
                .font(.nutola(13, .semibold))
                .foregroundStyle(Theme.secondary(scheme))

            VStack(spacing: 0) {
                ForEach(recentMeetings) { meeting in
                    Button {
                        launchRecent(meeting)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(meeting.title)
                                .font(.nutola(13, .medium))
                                .foregroundStyle(Theme.heading(scheme))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(PastRelativeFormatter.ago(meeting.createdAt))
                                .font(.nutola(11))
                                .foregroundStyle(Theme.tertiary(scheme))
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!available || isAnswering)

                    if meeting.id != recentMeetings.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recipes")
                .font(.nutola(13, .semibold))
                .foregroundStyle(Theme.secondary(scheme))

            FlowLayout(spacing: 8) {
                ForEach(recipeStore.all()) { recipe in
                    Button {
                        launch(recipe.prompt)
                    } label: {
                        RecipeChip(text: recipe.name)
                    }
                    .buttonStyle(.plain)
                    .disabled(!available || isAnswering)
                    .opacity(available && !isAnswering ? 1 : 0.45)
                    .contextMenu {
                        Button("Delete recipe", role: .destructive) {
                            recipeStore.delete(id: recipe.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footerNotices: some View {
        if launchFailed {
            Label(failureMessage, systemImage: "exclamationmark.triangle")
                .font(.nutola(11))
                .foregroundStyle(.orange)
        }

        if !available {
            unavailableNotice
        } else if preferredAIProvider == .apple {
            Text("Answers run on-device with your meeting summaries embedded in the prompt.")
                .font(.nutola(11))
                .foregroundStyle(Theme.tertiary(scheme))
        } else if effectiveMode == .app {
            Text(
                "Tip: once the nutola connector is set up, open \(preferredAIProvider.displayName) anytime — use $nutola to attach the connector."
            )
            .font(.nutola(11))
            .foregroundStyle(Theme.tertiary(scheme))
        } else {
            Text(
                "Answers run through the \(preferredAIProvider.displayName) CLI with meeting data included in the prompt. Tap the badge to switch assistants."
            )
            .font(.nutola(11))
            .foregroundStyle(Theme.tertiary(scheme))
        }
    }

    private var failureMessage: String {
        switch preferredAIProvider {
        case .apple: "Couldn't get an answer from Apple Intelligence."
        case .claude, .codex, .opencode, .vibe:
            switch effectiveMode {
            case .app: "Couldn't open \(preferredAIProvider.displayName)."
            case .cli: "Couldn't get an answer from \(preferredAIProvider.displayName)."
            }
        }
    }

    @ViewBuilder
    private var unavailableNotice: some View {
        switch preferredAIProvider {
        case .apple:
            VStack(alignment: .leading, spacing: 6) {
                Label("Apple Intelligence unavailable", systemImage: "exclamationmark.triangle")
                    .font(.nutola(12, .semibold))
                    .foregroundStyle(.orange)
                Text(AppleSummarizer.unavailableReason ?? "Turn on Apple Intelligence in System Settings, or pick a CLI assistant from the badge.")
                    .font(.nutola(11))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .padding(12)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        case .claude:
            cliUnavailableNotice(
                title: askDeliveryMode == .cli
                    ? (ClaudeCLI.isInstalled ? "Claude Code isn't logged in" : "Claude Code isn't installed")
                    : "Claude Desktop isn't installed",
                linkTitle: askDeliveryMode == .cli ? "Get Claude Code" : "Get Claude Desktop",
                linkURL: askDeliveryMode == .cli
                    ? URL(string: "https://claude.com/claude-code")!
                    : URL(string: "https://claude.ai/download")!
            )
        case .codex:
            cliUnavailableNotice(
                title: askDeliveryMode == .cli
                    ? (CodexCLI.isInstalled ? "Codex isn't logged in" : "Codex CLI isn't installed")
                    : "Codex app isn't installed",
                linkTitle: "Get Codex",
                linkURL: URL(string: "https://chatgpt.com/codex")!
            )
        case .opencode, .vibe:
            cliUnavailableNotice(
                title: "\(preferredAIProvider.displayName) CLI isn't installed",
                linkTitle: "Get \(preferredAIProvider.displayName)",
                linkURL: URL(string: preferredAIProvider == .opencode
                    ? "https://opencode.ai/docs/" : "https://docs.mistral.ai/vibe/code/overview")!)
        }
    }

    private func cliUnavailableNotice(title: String, linkTitle: String, linkURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.nutola(12, .semibold))
                .foregroundStyle(.orange)
            HStack(spacing: 4) {
                Link(linkTitle, destination: linkURL)
                Text("— then configure the CLI and select it in Settings.")
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .font(.nutola(11))
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func launchRecent(_ meeting: Meeting) {
        guard let builder = meetingPromptBuilder else { return }
        let question = "What were the key takeaways?"
        submit(
            displayText: "\(meeting.title) — \(question)",
            prompt: builder(meeting, question)
        )
    }

    private func launch(_ question: String) {
        submit(displayText: question, prompt: promptBuilder(question))
    }

    private func submit(displayText: String, prompt: String) {
        launchFailed = false
        messages.append(AskChatMessage(role: .user, text: displayText))

        switch effectiveMode {
        case .app:
            launchFailed = !AIAsk.open(prompt: prompt)
            if !launchFailed { input = "" }
        case .cli:
            guard available else {
                launchFailed = true
                return
            }
            beginCLIAnswer(prompt: prompt)
        }
    }

    private func beginCLIAnswer(prompt: String) {
        answerTask?.cancel()
        AIAsk.cancel()

        let loadingID = UUID()
        loadingMessageID = loadingID
        messages.append(AskChatMessage(id: loadingID, role: .assistant, text: "", isLoading: true))
        isAnswering = true

        answerTask = Task {
            do {
                let text = try await AIAsk.answer(prompt: prompt) { delta in
                    Task { @MainActor in
                        updateLoadingMessage(text: delta)
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    finishLoadingMessage(text: text)
                    isAnswering = false
                    answerTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    removeLoadingMessage()
                    isAnswering = false
                    answerTask = nil
                }
            } catch {
                guard !Task.isCancelled else {
                    await MainActor.run {
                        removeLoadingMessage()
                        isAnswering = false
                        answerTask = nil
                    }
                    return
                }
                await MainActor.run {
                    NutolaConsoleLog.ask("answer failed — \(error.localizedDescription)")
                    finishLoadingMessage(text: error.localizedDescription, isError: true)
                    isAnswering = false
                    launchFailed = true
                    answerTask = nil
                }
            }
        }
    }

    private func stopAnswering() {
        answerTask?.cancel()
        AIAsk.cancel()
        removeLoadingMessage()
        isAnswering = false
        answerTask = nil
    }

    private func updateLoadingMessage(text: String) {
        guard let loadingMessageID,
              let index = messages.firstIndex(where: { $0.id == loadingMessageID })
        else { return }
        messages[index] = AskChatMessage(
            id: loadingMessageID,
            role: .assistant,
            text: text,
            isLoading: text.isEmpty
        )
    }

    private func finishLoadingMessage(text: String, isError: Bool = false) {
        guard let loadingMessageID,
              let index = messages.firstIndex(where: { $0.id == loadingMessageID })
        else { return }
        messages[index] = AskChatMessage(
            id: loadingMessageID,
            role: .assistant,
            text: text,
            isLoading: false,
            isError: isError
        )
        self.loadingMessageID = nil
    }

    private func removeLoadingMessage() {
        guard let loadingMessageID else { return }
        messages.removeAll { $0.id == loadingMessageID }
        self.loadingMessageID = nil
    }

    private func launchTyped() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isAnswering else { return }
        input = ""
        launch(text)
    }
    private func submitInitialQuestionIfNeeded() {
        guard !didSubmitInitialQuestion, let question = initialQuestion?.trimmingCharacters(in: .whitespaces), !question.isEmpty else { return }
        didSubmitInitialQuestion = true
        launch(question)
    }

    /// One-shot seed: the first time the launcher appears, copy the built-in
    /// `suggestions` into the user's recipe library so the chips look exactly
    /// as before this feature. Gated by a UserDefaults flag (`didSeedRecipes`)
    /// rather than "library is empty" so a user who deletes every recipe
    /// doesn't get the defaults silently re-added on the next appear.
    private func seedRecipesFromSuggestionsIfNeeded() {
        guard !AppSettings.defaults.bool(forKey: SettingsKey.didSeedRecipes),
              !suggestions.isEmpty else { return }
        for suggestion in suggestions {
            recipeStore.add(name: suggestion, prompt: suggestion)
        }
        AppSettings.defaults.set(true, forKey: SettingsKey.didSeedRecipes)
    }

    private func saveCurrentInputAsRecipe() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let name = String(text.prefix(40))
        recipeStore.add(name: name, prompt: text)
        didSaveRecipe = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didSaveRecipe = false }
    }
}

private struct AskChatBubble: View {
    let message: AskChatMessage

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var didCopy = false

    private var canCopy: Bool {
        !message.isLoading && !message.text.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 56) }

            bubbleContent
                .onHover { isHovering = $0 }

            if message.role == .assistant { Spacer(minLength: 56) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if message.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Asking \(AppSettings.preferredAIProvider.displayName)…")
                            .font(.nutola(13))
                            .foregroundStyle(Theme.secondary(scheme))
                    }
                } else if message.role == .assistant {
                    MarkdownText(markdown: message.text, style: .document)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(message.text)
                        .font(.nutola(14))
                        .foregroundStyle(Theme.heading(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .padding(.top, canCopy && isHovering ? 4 : 0)
            .background(
                message.isError
                    ? Color.orange.opacity(scheme == .dark ? 0.14 : 0.1)
                    : Theme.bubble(scheme, isSelf: message.role == .user),
                in: RoundedRectangle(cornerRadius: 14)
            )

            if canCopy, isHovering {
                copyButton
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var copyButton: some View {
        Button(action: copyText) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary(scheme))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(scheme == .dark ? 0.22 : 0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(didCopy ? "Copied" : "Copy")
        .accessibilityLabel("Copy message")
        .accessibilityValue(didCopy ? "Copied" : "")
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
    }
}

private struct AskChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    var isLoading: Bool
    var isError: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isLoading: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isLoading = isLoading
        self.isError = isError
    }
}

private struct RecipeChip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        Text(text)
            .font(.nutola(12, .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.card(scheme), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .foregroundStyle(Theme.heading(scheme))
    }
}

private enum UserGreeting {
    static var firstName: String {
        let full = NSFullUserName()
        guard !full.isEmpty else { return "there" }
        return full.split(separator: " ").first.map(String.init) ?? full
    }
}

private enum PastRelativeFormatter {
    static func ago(_ date: Date, now: Date = .now) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }
        let months = days / 30
        if months < 12 { return "\(months)mo" }
        return "\(days / 365)y"
    }
}

enum MeetingAISuggestions {
    static func forMeeting(_ meeting: Meeting) -> [String] {
        var items = ["Summarize this meeting", "List action items", "Write follow-up email"]
        if let speaker = meeting.speakers.first(where: { !$0.isMe }) {
            items.append("What did \(speaker.name) say?")
        }
        return items
    }

    static let library = [
        "Summarize my meetings this week",
        "What action items do I have?",
        "What decisions came out of recent calls?",
        "List open questions from recent meetings",
        "Who have I met with most this month?",
    ]
}
