import Foundation
import SwiftUI

/// UserDefaults-backed settings. Keys are shared with @AppStorage in Settings UI.
enum SettingsKey {
    static let autoRecord = "autoRecord"                    // start recording on detection (vs. just show the prompt card)
    static let detectMeetings = "detectMeetings"            // watch for mic activity at all
    static let identifySpeakers = "identifySpeakers"        // run on-device diarization
    static let useCalendar = "useCalendar"                  // match calendar events for titles/attendees
    static let upcomingCountdownHours = "upcomingCountdownHours" // show "in 52m" when next event is within this window
    static let showUpcomingInMenuBar = "showUpcomingInMenuBar"   // menu-bar countdown + coming-up strip
    static let showEventsWithoutParticipants = "showEventsWithoutParticipants"
    static let disabledCalendarIDs = "disabledCalendarIDs"       // empty = all calendars visible
    static let defaultTemplate = "defaultTemplate"
    static let ignoredBundleIDs = "ignoredBundleIDs"        // apps that never count as meetings
    static let autoStopRecording = "autoStopRecording"      // stop ~8s after the meeting app releases the mic
    static let didCompleteOnboarding = "didCompleteOnboarding" // first-run walkthrough finished
    static let systemAudioConfirmed = "systemAudioConfirmed"   // tap has captured real (non-silent) audio at least once
    static let preferClaudeSummaries = "preferClaudeSummaries" // prefer cloud AI for summaries first (vs. Apple-first)
    static let preferredAIProvider = "preferredAIProvider"     // apple | claude | codex | opencode | vibe
    static let askDeliveryMode = "askDeliveryMode"             // cli | app
    static let askMaxTurns = "askMaxTurns"                     // MCP tool rounds for CLI ask
    static let appearanceMode = "appearanceMode"               // system | light | dark
    static let actionColorHex = "actionColorHex"               // prominent buttons (Record, Save, …)
    static let recordingCardOriginX = "recordingCardOriginX"   // last user-placed floating card origin
    static let recordingCardOriginY = "recordingCardOriginY"
    static let showLiveRecordingCard = "showLiveRecordingCard" // floating live transcript widget
    static let openMainWindowAtLaunch = "openMainWindowAtLaunch" // show main window on launch (vs. menu bar only)
    static let sideNotesPanelWidth = "sideNotesPanelWidth"
    static let transcriptionModel = "transcriptionModel" // apple | parakeetRedux | parakeetUltra
    static let developerMode = "developerMode"                 // show Debug settings tab
    static let crashDiagnostics = "crashDiagnostics"           // write a scrubbed diagnostic on crash (opt-in)
    static let recipes = "recipes"                     // saved Ask Claude prompt library (RecipeStore)
    static let tokenUsageHistory = "token-usage-history"      // [DailyTokenUsage] JSON: last 14 days of AI token usage
    static let didSeedRecipes = "didSeedRecipes"           // one-shot flag: built-in suggestions seeded into RecipeStore
    static let archivedEventTitles = "archivedEventTitles"   // calendar events hidden by title (series)
    static let archivedEventIDs = "archivedEventIDs"         // individual calendar events hidden by ID
    static let hourlyRatePerPerson = "hourlyRatePerPerson" // estimated $/hr per attendee for the meeting-cost badge
    static let showMeetingCost = "showMeetingCost"           // display the 💰 cost badge in the meeting header
    static let smartTemplatesEnabled = "smartTemplatesEnabled" // auto-pick summary template by meeting type
    static let fillerRemoval = "fillerRemoval"                 // strip uh/um/er/hmm from transcripts before summarizing
    static let personalDictionary = "personalDictionary"         // [PersonalDictionaryStore.Entry] JSON: custom vocab + replacements
    static let taskTracker = "taskTracker"                       // [TrackedTask] JSON: persistent activity tracker
    static let ownerAliases = "ownerAliases"                     // [OwnerAlias] JSON: merge rule "You/Taylor" → "Taylor"
    static let currentUserName = "currentUserName"              // display name for "me" — used by the activity tracker
}

enum AppearanceMode: String, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable, Hashable {
    case apple
    case claude
    case codex
    case opencode
    case vibe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .vibe: "Mistral Vibe"
        }
    }

    var isCloud: Bool { self != .apple }
    var supportsApp: Bool { self == .claude || self == .codex }
    var deliveryModes: [AskDeliveryMode] { supportsApp ? AskDeliveryMode.allCases : [.cli] }

    /// Assistants that can answer questions about meetings in-app.
    static let askChoices: [AIProvider] = allCases

    var isAvailableForSummary: Bool {
        switch self {
        case .apple: AppleSummarizer.isAvailable
        case .claude: ClaudeCLI.isInstalled && ClaudeCLI.isLoggedIn()
        case .codex: CodexCLI.isReady
        case .opencode, .vibe: AgentCLI.isInstalled(self)
        }
    }
}

enum AskDeliveryMode: String, CaseIterable, Identifiable, Hashable {
    case cli
    case app

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cli: "Answer here"
        case .app: "Open in app"
        }
    }

    var detail: String {
        switch self {
        case .cli: "Runs the CLI in the background and shows the answer in Nutola."
        case .app: "Opens Claude Desktop or Codex with a pre-filled prompt."
        }
    }
}

enum AppSettings {
    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        // Migrate choices whose downloads never had a working inference engine.
        // Keep files on disk until the user explicitly opts to remove them.
        if let old = defaults.string(forKey: SettingsKey.transcriptionModel),
            ["parakeetStreaming", "parakeetBatch", "nemotron"].contains(old) {
            defaults.set(TranscriptionModel.apple.rawValue, forKey: SettingsKey.transcriptionModel)
        }
        defaults.register(defaults: [
            SettingsKey.autoRecord: false,
            SettingsKey.detectMeetings: true,
            SettingsKey.identifySpeakers: true,
            SettingsKey.useCalendar: true,
            SettingsKey.upcomingCountdownHours: 3.0,
            SettingsKey.showUpcomingInMenuBar: true,
            SettingsKey.showEventsWithoutParticipants: true,
            SettingsKey.defaultTemplate: "Meeting Notes",
            SettingsKey.ignoredBundleIDs: defaultIgnoredBundleIDs,
            SettingsKey.autoStopRecording: true,
            SettingsKey.didCompleteOnboarding: false,
            SettingsKey.systemAudioConfirmed: false,
            SettingsKey.preferClaudeSummaries: false,
            SettingsKey.preferredAIProvider: AIProvider.apple.rawValue,
            SettingsKey.askDeliveryMode: AskDeliveryMode.cli.rawValue,
            SettingsKey.askMaxTurns: 5,
            SettingsKey.transcriptionModel: TranscriptionModel.apple.rawValue,
            SettingsKey.actionColorHex: Theme.defaultActionColorHex,
            SettingsKey.showLiveRecordingCard: true,
            SettingsKey.openMainWindowAtLaunch: true,
            SettingsKey.sideNotesPanelWidth: 280.0,
            SettingsKey.developerMode: false,
            SettingsKey.crashDiagnostics: false,
            SettingsKey.hourlyRatePerPerson: 100.0,
            SettingsKey.smartTemplatesEnabled: true,
            SettingsKey.fillerRemoval: false,
        ])
    }

    /// Apps whose mic use is never a meeting: voice assistants, dictation-ish utilities, ourselves.
    static let defaultIgnoredBundleIDs: [String] = [
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.VoiceMemos",
        "com.apple.controlcenter",
    ]

    static var autoRecord: Bool { defaults.bool(forKey: SettingsKey.autoRecord) }
    static var detectMeetings: Bool { defaults.bool(forKey: SettingsKey.detectMeetings) }
    static var identifySpeakers: Bool { defaults.bool(forKey: SettingsKey.identifySpeakers) }
    static var useCalendar: Bool { defaults.bool(forKey: SettingsKey.useCalendar) }
    static var upcomingCountdownHours: Double {
        let value = defaults.double(forKey: SettingsKey.upcomingCountdownHours)
        return value > 0 ? value : 3.0
    }
    static var showUpcomingInMenuBar: Bool { defaults.bool(forKey: SettingsKey.showUpcomingInMenuBar) }
    static var showEventsWithoutParticipants: Bool {
        defaults.bool(forKey: SettingsKey.showEventsWithoutParticipants)
    }
    static var disabledCalendarIDs: Set<String> {
        Set(defaults.stringArray(forKey: SettingsKey.disabledCalendarIDs) ?? [])
    }
    static func setCalendarEnabled(id: String, enabled: Bool) {
        var disabled = disabledCalendarIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(Array(disabled).sorted(), forKey: SettingsKey.disabledCalendarIDs)
    }
    static func resetCalendarSelection() {
        defaults.removeObject(forKey: SettingsKey.disabledCalendarIDs)
    }
    static func isCalendarEnabled(id: String) -> Bool {
        !disabledCalendarIDs.contains(id)
    }
    static var defaultTemplate: String {
        defaults.string(forKey: SettingsKey.defaultTemplate) ?? "Meeting Notes"
    }
    static var ignoredBundleIDs: [String] {
        defaults.stringArray(forKey: SettingsKey.ignoredBundleIDs) ?? defaultIgnoredBundleIDs
    }
    static var autoStopRecording: Bool { defaults.bool(forKey: SettingsKey.autoStopRecording) }
    static var didCompleteOnboarding: Bool { defaults.bool(forKey: SettingsKey.didCompleteOnboarding) }
    static var systemAudioConfirmed: Bool { defaults.bool(forKey: SettingsKey.systemAudioConfirmed) }
    static func markSystemAudioConfirmed() { defaults.set(true, forKey: SettingsKey.systemAudioConfirmed) }
    static var preferClaudeSummaries: Bool { defaults.bool(forKey: SettingsKey.preferClaudeSummaries) }
    static var preferredAIProvider: AIProvider {
        AIProvider(rawValue: defaults.string(forKey: SettingsKey.preferredAIProvider) ?? "") ?? .apple
    }
    static var askDeliveryMode: AskDeliveryMode {
        guard preferredAIProvider.supportsApp else { return .cli }
        return AskDeliveryMode(rawValue: defaults.string(forKey: SettingsKey.askDeliveryMode) ?? "") ?? .cli
    }
    static var askMaxTurns: Int {
        let value = defaults.integer(forKey: SettingsKey.askMaxTurns)
        return (3...15).contains(value) ? value : 5
    }
    static var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: SettingsKey.appearanceMode) ?? "") ?? .system
    }
    static var actionColorHex: String {
        defaults.string(forKey: SettingsKey.actionColorHex) ?? Theme.defaultActionColorHex
    }
    static var showLiveRecordingCard: Bool {
        defaults.bool(forKey: SettingsKey.showLiveRecordingCard)
    }
    static var openMainWindowAtLaunch: Bool {
        defaults.bool(forKey: SettingsKey.openMainWindowAtLaunch)
    }
    static var developerMode: Bool {
        defaults.bool(forKey: SettingsKey.developerMode)
    }
    static var crashDiagnostics: Bool {
        defaults.bool(forKey: SettingsKey.crashDiagnostics)
    }
    static var transcriptionModel: TranscriptionModel {
        TranscriptionModel(rawValue: defaults.string(forKey: SettingsKey.transcriptionModel) ?? "")
            ?? .apple
    }
    /// Estimated per-attendee hourly rate ($/hr) used by the meeting-cost badge.
    /// Defaults to 100.0; falls back to that when unset or non-positive.
    static var hourlyRatePerPerson: Double {
        let value = defaults.double(forKey: SettingsKey.hourlyRatePerPerson)
        return value > 0 ? value : 100.0
    }
    /// Whether the 💰 cost badge appears in the meeting header. Defaults to true.
    static var showMeetingCost: Bool {
        defaults.bool(forKey: SettingsKey.showMeetingCost)
    }
    /// Whether Nutola auto-selects a summary template based on detected meeting
    /// type (standup, interview, 1:1, …). When off, the user's default template
    /// is used for every meeting and no type badge is shown. Defaults to true.
    static var smartTemplatesEnabled: Bool {
        defaults.bool(forKey: SettingsKey.smartTemplatesEnabled)
    }

    /// Whether the pipeline strips verbal fillers (uh, um, er, hmm, …) from the
    /// transcript text before summarization. Off by default — a faithful record is
    /// usually what users want. Toggle in Settings → Meetings.
    static var fillerRemoval: Bool {
        defaults.bool(forKey: SettingsKey.fillerRemoval)
    }

    /// The user's display name, used by the activity tracker for "me" filtering.
    /// Defaults to the macOS full name, falling back to the short username.
    static var currentUserName: String {
        if let saved = defaults.string(forKey: SettingsKey.currentUserName),
           !saved.isEmpty {
            return saved
        }
        let full = NSFullUserName()
        if !full.isEmpty { return full }
        return NSUserName()
    }

    static func setCurrentUserName(_ name: String) {
        defaults.set(name, forKey: SettingsKey.currentUserName)
    }
}
