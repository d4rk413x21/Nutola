import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage(SettingsKey.developerMode) private var developerMode = false

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntelligenceSettings()
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            TranscriptionSettings()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            TemplateSettings()
                .tabItem { Label("Templates", systemImage: "doc.text") }
            CalendarSettings()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            if developerMode {
                DebugSettings()
                    .tabItem { Label("Debug", systemImage: "ladybug") }
            }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.detectMeetings) private var detectMeetings = true
    @AppStorage(SettingsKey.autoRecord) private var autoRecord = false
    @AppStorage(SettingsKey.autoStopRecording) private var autoStopRecording = true
    @AppStorage(SettingsKey.identifySpeakers) private var identifySpeakers = true
    @AppStorage(SettingsKey.fillerRemoval) private var fillerRemoval = false
    @AppStorage(SettingsKey.showLiveRecordingCard) private var showLiveRecordingCard = true
    @AppStorage(SettingsKey.defaultTemplate) private var defaultTemplate = "Meeting Notes"
    @AppStorage(SettingsKey.systemAudioConfirmed) private var systemAudioConfirmed = false

    @State private var micStatus = MicRecorder.permissionGranted
    @AppStorage(SettingsKey.openMainWindowAtLaunch) private var openMainWindowAtLaunch = true
    @AppStorage(SettingsKey.developerMode) private var developerMode = false
    @AppStorage(SettingsKey.crashDiagnostics) private var crashDiagnostics = false
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var systemAudioStatus = SystemAudioPermission.status()
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("Setup") {
                Toggle("Launch Nutola at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { applyLaunchAtLogin() }
                Text(LaunchAtLogin.requiresApproval
                     ? "Approve Nutola under System Settings → General → Login Items to finish enabling this."
                     : "Starts Nutola in the menu bar automatically when you log in.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Toggle("Open Nutola window at launch", isOn: $openMainWindowAtLaunch)
                Text("Shows the main window when Nutola starts. Turn off to stay in the menu bar until you open it.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Button("Run setup walkthrough again") { openWindow(id: "onboarding") }
                    .buttonStyle(.plain)
                    .font(.nutola(12))
                    .foregroundStyle(Theme.blueberry)
            }

            Section("Meetings") {
                Toggle("Detect meetings automatically", isOn: $detectMeetings)
                    .onChange(of: detectMeetings) {
                        detectMeetings ? app.startDetection() : app.stopDetection()
                    }
                Toggle("Start recording without asking", isOn: $autoRecord)
                    .disabled(!detectMeetings)
                Text("Nutola notices when another app starts using your microphone — Zoom, Meet, Teams, anything — and offers to record. Nothing is captured until recording starts.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Toggle("Stop recording automatically when the meeting ends", isOn: $autoStopRecording)
                    .disabled(!detectMeetings)
                Text("Waits ~8s after the meeting app releases the microphone, in case it reconnects.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Toggle("Show floating transcript while recording", isOn: $showLiveRecordingCard)
                    .onAppear { app.showLiveRecordingCard = showLiveRecordingCard }
                    .onChange(of: showLiveRecordingCard) { app.showLiveRecordingCard = showLiveRecordingCard }
                Text("The draggable live transcript card. Turn off to record from the menu bar only.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                if detectMeetings {
                    HStack(alignment: .top) {
                        StatusDot(ok: app.activeMicAppNames.isEmpty ? nil : true)
                        Text(app.activeMicAppNames.isEmpty
                             ? "No other app is using the microphone right now."
                             : "Currently hearing: \(app.activeMicAppNames.joined(separator: ", "))")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Understanding") {
                Toggle("Identify individual speakers", isOn: $identifySpeakers)
                Text("Separates different voices on the call using a small on-device model (~22 MB, downloaded once).")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Toggle("Remove filler words", isOn: $fillerRemoval)
                Text("Strips \"uh\", \"um\", \"er\", \"hmm\" and other disfluencies from the text used to generate notes. The saved transcript stays verbatim.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Picker("Default template", selection: $defaultTemplate) {
                    ForEach(app.templates.list()) { Text($0.name).tag($0.name) }
                }
            }

            Section("Permissions") {
                permissionRow(
                    ok: micStatus,
                    title: "Microphone",
                    detail: "Records your side of the call.") {
                    Task { micStatus = await MicRecorder.requestPermission() }
                }
                HStack(alignment: .firstTextBaseline) {
                    StatusDot(ok: systemAudioOK)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Audio Recording").font(.nutola(12, .medium))
                        Text(systemAudioSettingsDetail)
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch systemAudioStatus {
                    case .unknown:
                        Button("Grant…") {
                            Task {
                                await SystemAudioPermission.request()
                                systemAudioStatus = SystemAudioPermission.status()
                            }
                        }
                        .controlSize(.small)
                    case .denied:
                        Button("Open Settings") {
                            NSWorkspace.shared.open(SystemAudioPermission.privacySettingsURL)
                        }
                        .controlSize(.small)
                    case .authorized:
                        EmptyView()
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    StatusDot(ok: accessibilityTrusted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility").font(.nutola(12, .medium))
                        Text(accessibilitySettingsDetail)
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !accessibilityTrusted {
                        Button("Grant…") { AccessibilityPermission.request() }
                            .controlSize(.small)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(AccessibilityPermission.privacySettingsURL)
                        }
                        .controlSize(.small)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    StatusDot(ok: app.notificationAuthStatus == .authorized
                               ? true : (app.notificationAuthStatus == .denied ? false : nil))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications").font(.nutola(12, .medium))
                        Text("Lets Nutola notify you when a recording finishes processing and your notes are ready.")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.notificationAuthStatus == .notDetermined {
                        Button("Grant…") { Task { await app.requestNotificationAuthorization() } }
                            .controlSize(.small)
                    } else {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                        .controlSize(.small)
                    }
                }
                .task { await app.refreshNotificationStatus() }
            }

            Section {
                Toggle("Developer mode", isOn: $developerMode)
                    .onChange(of: developerMode) {
                        NutolaConsoleLog.app("developer mode \(developerMode ? "enabled" : "disabled")")
                        if developerMode {
                            NutolaConsoleLog.app("debug logging active — stderr + Debug tab")
                        }
                    }
                Text("Shows a Debug tab with diagnostics and experimental options.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Save a crash diagnostic on crash", isOn: $crashDiagnostics)
                Text("When Nutola crashes, writes a small scrubbed record (version, OS, signal, and the in-flight meeting's title and state — never audio, transcript, or notes) to ~/Library/Application Support/Nutola/diagnostics.json so you can attach it to a bug report. Off by default.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack {
                    Text("Nutola")
                        .font(.nutola(14, .semibold))
                    Spacer()
                    if let v = AppVersion.displayVersion {
                        Text(v)
                            .font(.nutola(12))
                            .foregroundStyle(.secondary)
                            .help("Version \(v) (build \(AppVersion.buildNumber))")
                    }
                }
                Link("Changelog",
                     destination: AppVersion.changelogURL)
                    .font(.nutola(11))
            }

            Section("Reset") {
                Button("Reset to Defaults", role: .destructive) {
                    showResetConfirm = true
                }
                Text("Restores detection, recording, transcription, and appearance settings to their defaults. Meetings and notes are not affected.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restores detection, recording, transcription, and appearance preferences to their defaults. Your meetings and notes are not affected.")
        }
        .formStyle(.grouped)
        .onAppear {
            micStatus = MicRecorder.permissionGranted
            launchAtLogin = LaunchAtLogin.isOn
            systemAudioStatus = SystemAudioPermission.status()
            accessibilityTrusted = AccessibilityPermission.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micStatus = MicRecorder.permissionGranted
            systemAudioStatus = SystemAudioPermission.status()
            accessibilityTrusted = AccessibilityPermission.isTrusted
        }
    }

    private var accessibilitySettingsDetail: String {
        accessibilityTrusted
            ? "Allowed — reads Zoom's active speaker to label who said what in the transcript."
            : "Optional — labels Zoom speakers by name. Click Grant, then enable Nutola under Accessibility."
    }

    private var systemAudioOK: Bool? {
        if systemAudioStatus == .authorized { return true }
        if systemAudioStatus == .denied { return false }
        return nil
    }

    private var systemAudioSettingsDetail: String {
        if systemAudioConfirmed, systemAudioStatus != .authorized {
            return "Previously captured call audio, but macOS no longer shows an active grant — click Grant to re-allow."
        }
        if systemAudioConfirmed {
            return "Records the other participants. Confirmed capturing audio in a previous recording."
        }
        switch systemAudioStatus {
        case .authorized:
            return "Allowed — records the other participants on calls."
        case .denied:
            return "Denied — enable Nutola under System Audio Recording Only in Settings."
        case .unknown:
            return "Records the other participants. Click Grant — macOS will ask to allow system audio recording."
        }
    }

    private func applyLaunchAtLogin() {
        try? LaunchAtLogin.set(launchAtLogin)
        launchAtLogin = LaunchAtLogin.isOn // reflect what actually took effect
    }

    private func resetToDefaults() {
        detectMeetings = true
        autoRecord = false
        autoStopRecording = true
        identifySpeakers = true
        showLiveRecordingCard = true
        defaultTemplate = "Meeting Notes"
        openMainWindowAtLaunch = true
        developerMode = false
        crashDiagnostics = false
        UserDefaults.standard.set(
            AppearanceMode.system.rawValue, forKey: SettingsKey.appearanceMode)
        UserDefaults.standard.set(
            Theme.defaultActionColorHex, forKey: SettingsKey.actionColorHex)
        NutolaConsoleLog.app("settings reset to defaults")
    }

    private func permissionRow(
        ok: Bool, title: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.nutola(12, .medium))
                Text(detail).font(.nutola(11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
    }
}

private struct CalendarSettings: View {
    @EnvironmentObject private var app: AppState
    @AppStorage(SettingsKey.useCalendar) private var useCalendar = true
    @AppStorage(SettingsKey.upcomingCountdownHours) private var upcomingCountdownHours = 3.0
    @AppStorage(SettingsKey.showUpcomingInMenuBar) private var showUpcomingInMenuBar = true
    @AppStorage(SettingsKey.showEventsWithoutParticipants) private var showEventsWithoutParticipants = true

    @State private var calendarStatus = CalendarAuthorization.isAuthorized
    @State private var calendars: [CalendarSourceInfo] = []
    @State private var disabledIDs: Set<String> = AppSettings.disabledCalendarIDs
    @StateObject private var archivedStore = ArchivedEventStore()
    var body: some View {
        Form {
            if !calendarStatus {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        StatusDot(ok: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Calendar access is required to show your schedule.")
                                .font(.nutola(12))
                            if CalendarAuthorization.isDenied {
                                Button("Open System Settings") {
                                    NSWorkspace.shared.open(URL(
                                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                                }
                                .controlSize(.small)
                            } else {
                                Button("Grant access…") {
                                    Task { await grantAccess() }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section("Display") {
                Toggle("Match calendar events", isOn: $useCalendar)
                    .onChange(of: useCalendar) {
                        Task { await app.calendar.refreshAgenda() }
                    }
                Text("Uses your calendar for titles, attendees, and the Coming up view.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                Toggle("Show upcoming meetings in menu bar", isOn: $showUpcomingInMenuBar)
                    .disabled(!useCalendar)
                Text("Displays your next meeting and time until it starts in the macOS menu bar.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                if useCalendar {
                    Stepper(value: $upcomingCountdownHours, in: 0.5...12, step: 0.5) {
                        Text("Countdown window: \(countdownLabel)")
                            .font(.nutola(12))
                    }
                }
                Toggle("Show events with no participants", isOn: $showEventsWithoutParticipants)
                    .disabled(!useCalendar)
                    .onChange(of: showEventsWithoutParticipants) {
                        Task { await app.calendar.refreshAgenda() }
                    }
                Text("Coming up includes events without attendees or a video link when on.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }

            if calendarStatus {
                Section {
                    HStack {
                        Text("Visible calendars")
                            .font(.nutola(12, .semibold))
                        Spacer()
                        Button("Reset") { resetCalendars() }
                            .buttonStyle(.plain)
                            .font(.nutola(11, .medium))
                            .foregroundStyle(Theme.blueberry)
                            .disabled(disabledIDs.isEmpty)
                    }
                    if calendars.isEmpty {
                        Text("No calendars found on this Mac.")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(calendars) { source in
                            calendarRow(source)
                        }
                    }
                    Text("Only events from enabled calendars appear in Coming up and when matching recordings.")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                }
            }

            if useCalendar {
                Section("Archived events") {
                    if !archivedStore.hasAny {
                        Text("No archived events. Right-click an event in Coming up to hide it.")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(archivedStore.archivedTitles).sorted(), id: \.self) { title in
                            HStack {
                                Label(title, systemImage: "archivebox.fill")
                                    .font(.nutola(12))
                                Spacer()
                                Button {
                                    archivedStore.unarchiveTitle(title)
                                    Task { await app.calendar.refreshAgenda() }
                                } label: {
                                    Image(systemName: "arrow.up.out.of.square")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.blueberry)
                                .help("Unarchive series")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                archivedStore.unarchiveTitle(title)
                                Task { await app.calendar.refreshAgenda() }
                            }
                        }
                        ForEach(archivedStore.archivedEvents) { evt in
                            HStack {
                                Label(evt.title, systemImage: "archivebox")
                                    .font(.nutola(12))
                                Spacer()
                                Button {
                                    archivedStore.unarchiveEvent(id: evt.id)
                                    Task { await app.calendar.refreshAgenda() }
                                } label: {
                                    Image(systemName: "arrow.up.out.of.square")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.blueberry)
                                .help("Unarchive event")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                archivedStore.unarchiveEvent(id: evt.id)
                                Task { await app.calendar.refreshAgenda() }
                            }
                        }
                        Divider()
                        Button {
                            archivedStore.clearAll()
                            Task { await app.calendar.refreshAgenda() }
                        } label: {
                            Label("Unarchive all", systemImage: "arrow.up.out.of.square")
                                .font(.nutola(11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.blueberry)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadCalendars() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarStatus = CalendarAuthorization.isAuthorized
            reloadCalendars()
        }
    }

    private func calendarRow(_ source: CalendarSourceInfo) -> some View {
        Toggle(isOn: calendarBinding(source.id)) {
            HStack(spacing: 8) {
                Circle()
                    .fill(source.color)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.nutola(12, .medium))
                    if let account = source.sourceTitle, account != source.title {
                        Text(account)
                            .font(.nutola(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(!useCalendar)
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !disabledIDs.contains(id) },
            set: { enabled in
                if enabled { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
                AppSettings.setCalendarEnabled(id: id, enabled: enabled)
                Task { await app.calendar.refreshAgenda() }
            })
    }

    private var countdownLabel: String {
        upcomingCountdownHours == floor(upcomingCountdownHours)
            ? "\(Int(upcomingCountdownHours)) hours"
            : String(format: "%.1f hours", upcomingCountdownHours)
    }

    private func reloadCalendars() {
        calendarStatus = CalendarAuthorization.isAuthorized
        disabledIDs = AppSettings.disabledCalendarIDs
        calendars = CalendarSources.all()
    }

    private func grantAccess() async {
        calendarStatus = await CalendarAuthorization.requestAccess()
        reloadCalendars()
        await app.calendar.resetEventStoreAfterGrant()
    }

    private func resetCalendars() {
        AppSettings.resetCalendarSelection()
        disabledIDs = []
        Task { await app.calendar.refreshAgenda() }
    }
}

private struct IntelligenceSettings: View {
    @Environment(\.nutolaActionColor) private var actionColor
    @State private var claudeInstalled = false
    @State private var claudeLoggedIn = false
    @State private var ghAvailable = false
    @State private var claudeCodeAvailable = false
    @State private var codexInstalled = false
    @State private var codexLoggedIn = false
    @State private var codexSetupAvailable = false
    @State private var claudeVersion: String?
    @State private var codexVersion: String?
    @State private var additionalInstalled: [AIProvider: Bool] = [:]
    @AppStorage(SettingsKey.preferClaudeSummaries) private var preferClaudeSummaries = false
    @AppStorage(SettingsKey.preferredAIProvider) private var preferredAIProvider: AIProvider = .apple
    @AppStorage(SettingsKey.askDeliveryMode) private var askDeliveryMode: AskDeliveryMode = .cli
    @AppStorage(SettingsKey.askMaxTurns) private var askMaxTurns = 5

    /// #15 — Path to the Claude Desktop MCP config file, centralized so the
    /// path string and the derived URL stay in one place.
    private static let claudeDesktopConfigPath =
        "Library/Application Support/Claude/claude_desktop_config.json"

    private var cloudAssistantReady: Bool {
        switch preferredAIProvider {
        case .apple: AppleSummarizer.isAvailable
        case .claude: claudeInstalled && claudeLoggedIn
        case .codex: codexInstalled && codexLoggedIn
        case .opencode, .vibe: additionalInstalled[preferredAIProvider] == true
        }
    }

    var body: some View {
        Form {
            Section("On-device") {
                statusRow(
                    ok: AppleSummarizer.isAvailable,
                    title: "Apple Intelligence",
                    detail: AppleSummarizer.isAvailable
                        ? "Summaries, titles, and meeting chat run entirely on this Mac."
                        : (AppleSummarizer.unavailableReason ?? "Unavailable"))
                statusRow(
                    ok: true,
                    title: "Speech transcription",
                    detail: "Apple's on-device speech model. English and Brazilian Portuguese are prepared automatically; other system languages download on first use.")
            }

            Section("CLI versions") {
                versionRow(title: "Claude Code", version: claudeVersion, installed: claudeInstalled)
                versionRow(title: "Codex CLI", version: codexVersion, installed: codexInstalled)
            }

            Section("Your Claude account") {
                statusRow(
                    ok: claudeInstalled && claudeLoggedIn,
                    title: claudeInstalled
                        ? (claudeLoggedIn ? "Claude Code — connected" : "Claude Code — not logged in")
                        : "Claude Code — not installed",
                    detail: claudeInstalled
                        ? (claudeLoggedIn
                            ? "Used as a fallback when a meeting is too long for the on-device model to summarize. Billed to your own Claude plan."
                            : "Open Claude Code and log in once to enable this.")
                        : "Install from claude.com/claude-code to unlock long-meeting summaries when Apple Intelligence can't fit the transcript.")
                actionRow(
                    ok: ghAvailable,
                    title: ghAvailable ? "GitHub CLI — ready" : "GitHub CLI — not found",
                    detail: "Publishes meeting pages as secret gists on your own GitHub account."
                ) {
                    if !ghAvailable {
                        Button("Set it up with Claude") { ClaudeCode.setUpGitHubCLI() }
                            .controlSize(.small)
                            .disabled(!claudeCodeAvailable)
                    }
                }

                if preferredAIProvider.isCloud {
                    Toggle("Always use \(preferredAIProvider.displayName) for summaries", isOn: $preferClaudeSummaries)
                        .disabled(!cloudAssistantReady)
                    Text("On: every summary via \(preferredAIProvider.displayName). Off: \(preferredAIProvider.displayName) first, with Apple Intelligence only if it fails.")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ask AI") {
                Picker("Assistant", selection: $preferredAIProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text("Choose which assistant Nutola uses for meeting chat and summaries.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)

                if preferredAIProvider.isCloud {
                    if preferredAIProvider.supportsApp {
                        Picker("Answer with", selection: $askDeliveryMode) {
                            ForEach(preferredAIProvider.deliveryModes) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Text(askDeliveryMode.detail)
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Answers are shown here using your CLI's configured account and model.")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    }

                    if preferredAIProvider.supportsApp && askDeliveryMode == .cli {
                        Stepper("Context rounds: \(askMaxTurns)", value: $askMaxTurns, in: 3...15)
                        Text("How many tool rounds the CLI can use to search and read meetings. Raise this for long transcripts.")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                    }
                }

                switch preferredAIProvider {
                case .apple:
                    statusRow(
                        ok: AppleSummarizer.isAvailable,
                        title: "Apple Intelligence",
                        detail: AppleSummarizer.isAvailable
                            ? "Summaries and titles run entirely on this Mac. Pick Claude or Codex above to ask about meetings in chat."
                            : (AppleSummarizer.unavailableReason ?? "Unavailable on this Mac."))
                case .codex:
                    statusRow(
                        ok: codexInstalled && codexLoggedIn,
                        title: aiProviderStatusDescription(
                            provider: .codex, installed: codexInstalled, loggedIn: codexLoggedIn),
                        detail: aiProviderStatusDescription(
                            provider: .codex, installed: codexInstalled, loggedIn: codexLoggedIn,
                            forDetail: true))
                case .claude:
                    statusRow(
                        ok: claudeInstalled && claudeLoggedIn,
                        title: aiProviderStatusDescription(
                            provider: .claude, installed: claudeInstalled, loggedIn: claudeLoggedIn),
                        detail: aiProviderStatusDescription(
                            provider: .claude, installed: claudeInstalled, loggedIn: claudeLoggedIn,
                            forDetail: true))
                case .opencode, .vibe:
                    statusRow(
                        ok: additionalInstalled[preferredAIProvider] == true,
                        title: aiProviderStatusDescription(provider: preferredAIProvider,
                            installed: additionalInstalled[preferredAIProvider] == true, loggedIn: false),
                        detail: aiProviderStatusDescription(provider: preferredAIProvider,
                            installed: additionalInstalled[preferredAIProvider] == true, loggedIn: false, forDetail: true))
                }
            }

            if preferredAIProvider.supportsApp {
                Section("Connect \(preferredAIProvider.displayName) to your meetings") {
                    connectAIContent
                }
            }

            Section("Token usage") {
                TokenUsageChart()
                Text("Approximate tokens used by summaries, titles, and Ask AI over the last 14 days. Counts are estimated (~4 chars/token) since the CLIs don't report billing-grade usage.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Clear history", role: .destructive) {
                        TokenUsageTracker.shared.clear()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            claudeInstalled = ClaudeCLI.isInstalled
            codexInstalled = CodexCLI.isInstalled
            ghAvailable = GitHubGist.isAvailable
            claudeCodeAvailable = ClaudeCode.isAvailable
            codexSetupAvailable = CodexSetup.isAvailable
            Task.detached {
                let loggedIn = ClaudeCLI.isLoggedIn()
                let codexIn = CodexCLI.isLoggedIn()
                let claudeV = ClaudeCLI.version()
                let codexV = CodexCLI.version()
                var installed: [AIProvider: Bool] = [:]
                for provider in [AIProvider.opencode, .vibe] {
                    installed[provider] = AgentCLI.resolveBlocking(provider) != nil
                }
                let additional = installed
                await MainActor.run {
                    claudeLoggedIn = loggedIn
                    codexLoggedIn = codexIn
                    claudeVersion = claudeV
                    codexVersion = codexV
                    additionalInstalled = additional
                    logAssistantStatus()
                }
            }
        }
        .onChange(of: preferredAIProvider) { logAssistantStatus() }
        .onChange(of: preferClaudeSummaries) { logAssistantStatus() }
    }

    private func logAssistantStatus() {
        NutolaConsoleLog.intelligence("── Intelligence settings ──")
        NutolaConsoleLog.intelligence("Assistant: \(preferredAIProvider.displayName)")
        NutolaConsoleLog.intelligence("Always use cloud for summaries: \(preferClaudeSummaries) (cloud-only when on)")
        if AppleSummarizer.isAvailable {
            NutolaConsoleLog.intelligence("Apple Intelligence: available")
        } else {
            NutolaConsoleLog.intelligence("Apple Intelligence: \(AppleSummarizer.unavailableReason ?? "unavailable")")
        }
        NutolaConsoleLog.intelligence(
            "Claude: \(claudeInstalled ? "installed" : "not installed")"
                + (claudeInstalled ? ", \(claudeLoggedIn ? "logged in" : "not logged in")" : ""))
        NutolaConsoleLog.intelligence(
            "Codex: \(codexInstalled ? "installed" : "not installed")"
                + (codexInstalled ? ", \(codexLoggedIn ? "logged in" : "not logged in")" : "")
                + ", ready: \(CodexCLI.isReady)")
    }

    // #13 — Centralizes the "connected / not logged in / not installed" status
    // strings that were previously inlined in the Ask AI switch block.
    private func aiProviderStatusDescription(
        provider: AIProvider, installed: Bool, loggedIn: Bool, forDetail: Bool = false
    ) -> String {
        switch provider {
        case .apple:
            if forDetail {
                return AppleSummarizer.isAvailable
                    ? "Summaries and titles run entirely on this Mac. Pick Claude or Codex above to ask about meetings in chat."
                    : (AppleSummarizer.unavailableReason ?? "Unavailable on this Mac.")
            }
            return AppleSummarizer.isAvailable ? "Apple Intelligence — ready" : "Apple Intelligence — unavailable"
        case .claude:
            if !installed {
                return forDetail
                    ? "Install from claude.com/claude-code to ask about your meetings through Claude."
                    : "Claude Code — not installed"
            }
            if !loggedIn {
                return forDetail
                    ? "Open Claude Code and log in once to enable this."
                    : "Claude Code — not logged in"
            }
            return forDetail
                ? "Ask about your meetings from Claude once the nutola connector is set up."
                : "Claude Code — connected"
        case .codex:
            if !installed {
                return forDetail
                    ? "Install from chatgpt.com/codex to ask about your meetings through Codex."
                    : "Codex CLI — not installed"
            }
            if !loggedIn {
                return forDetail
                    ? "Run `codex login` once to enable this."
                    : "Codex CLI — not logged in"
            }
            return forDetail
                ? "Ask about your meetings from Codex once the nutola connector is set up."
                : "Codex CLI — connected"
        case .opencode, .vibe:
            if forDetail {
                let command = provider == .opencode ? "opencode" : "vibe"
                return "Run `\(command)` in Terminal to configure its account and model. Nutola uses that configuration; account errors are reported when a request runs."
            }
            return "\(provider.displayName) CLI — \(installed ? "installed" : "not installed")"
        }
    }

    private var binaryPath: String {
        Bundle.main.executablePath ?? "/Applications/Nutola.app/Contents/MacOS/Nutola"
    }

    private var mcpCommand: String {
        "claude mcp add nutola -s user -- \"\(binaryPath)\" --mcp"
    }

    private var mcpDesktopConfigSnippet: String {
        """
        {
          "mcpServers": {
            "nutola": {
              "command": "\(binaryPath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    private var claudeDesktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.claudeDesktopConfigPath)
    }

    private var codexConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    private var codexMCPCommand: String {
        "codex mcp add nutola -- \"\(binaryPath)\" --mcp"
    }

    @ViewBuilder
    private var connectAIContent: some View {
        switch preferredAIProvider {
        case .apple, .opencode, .vibe:
            EmptyView()
        case .claude:
            VStack(alignment: .leading, spacing: 8) {
                Text("Give Claude access to your meeting library. Everything stays local — the connector just reads Nutola's on-disk library.")
                    .font(.nutola(12))

                HStack {
                    Button("Add to Claude Code") { ClaudeCode.addMCPServer(binary: binaryPath) }
                        .buttonStyle(.borderedProminent)
                        .tint(actionColor)
                    Button("Add to Claude Desktop") {
                        ClaudeCode.addToClaudeDesktop(
                            binary: binaryPath, configPath: claudeDesktopConfigURL.path)
                    }
                }
                .controlSize(.small)
                .disabled(!claudeCodeAvailable)

                Text(claudeCodeAvailable
                     ? "Claude Code runs the setup for you and confirms it worked."
                     : "Install Claude Desktop (it includes Claude Code) to use these buttons.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)

                DisclosureGroup("Prefer to run it yourself?") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(mcpCommand)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(mcpCommand, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy the claude mcp add command")
                        }
                        Text("Or add the \"nutola\" entry to Claude Desktop's config (merge into any existing \"mcpServers\"):")
                            .font(.nutola(11))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy JSON") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(mcpDesktopConfigSnippet, forType: .string)
                            }
                            Button("Reveal config in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([claudeDesktopConfigURL])
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .font(.nutola(11))
            }
        case .codex:
            VStack(alignment: .leading, spacing: 8) {
                Text("Give Codex access to your meeting library. Everything stays local — the connector just reads Nutola's on-disk library. Use $nutola (not @) to attach it.")
                    .font(.nutola(12))

                HStack {
                    Button("Add with Codex") { CodexSetup.addMCPServer(binary: binaryPath) }
                        .buttonStyle(.borderedProminent)
                        .tint(actionColor)
                        .disabled(!codexSetupAvailable)
                }
                .controlSize(.small)

                Text(codexSetupAvailable
                     ? "Codex runs the setup and confirms it worked."
                     : "Install and log in to Codex CLI to use this button.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)

                DisclosureGroup("Prefer to run it yourself?") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(codexMCPCommand)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(codexMCPCommand, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy the codex mcp add command")
                        }
                        Button("Reveal config in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([codexConfigURL])
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .font(.nutola(11))
            }
        }
    }

    private func statusRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.nutola(12, .medium))
                Text(detail).font(.nutola(11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func actionRow<Action: View>(
        ok: Bool, title: String, detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.nutola(12, .medium))
                Text(detail).font(.nutola(11)).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }

    /// #97 — read-only row showing the installed CLI version (or "not installed").
    private func versionRow(title: String, version: String?, installed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(ok: installed)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.nutola(12, .medium))
                Text(installed ? (version ?? "Installed") : "Not installed")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct TemplateSettings: View {
    @Environment(\.nutolaActionColor) private var actionColor
    @EnvironmentObject private var app: AppState
    @State private var templates: [SummaryTemplate] = []
    @State private var selected: String?
    @State private var draftName = ""
    @State private var draftBody = ""
    @State private var saveError: String?
    @State private var deleteError: String?
    @State private var showAISheet = false
    @State private var aiPrompt = ""
    @State private var aiError: String?
    @State private var isGenerating = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(templates, id: \.name, selection: $selected) { template in
                    Text(template.name).font(.nutola(12)).tag(template.name)
                }
                HStack(spacing: 8) {
                    Button {
                        var name = "New Template"
                        var n = 2
                        while templates.contains(where: { $0.name == name }) {
                            name = "New Template \(n)"; n += 1
                        }
                        try? app.templates.save(SummaryTemplate(
                            name: name,
                            body: "# {{title}}\n\n## Highlights\nWhat mattered most.\n"))
                        reload(select: name)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New template")
                    Button {
                        guard let selected else {
                            NutolaConsoleLog.app("[TemplateSettings] delete: no selection")
                            return
                        }
                        NutolaConsoleLog.app("[TemplateSettings] delete: \(selected)")
                        do {
                            try app.templates.delete(named: selected)
                            NutolaConsoleLog.app("[TemplateSettings] delete succeeded, reloading")
                            reload(select: nil)
                            deleteError = nil
                        } catch {
                            NutolaConsoleLog.app("[TemplateSettings] delete failed: \(error)")
                            deleteError = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    .help("Delete template")
                    Button {
                        aiError = nil; showAISheet = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .help("Generate template with AI")
                    Spacer()
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .frame(minWidth: 150, maxWidth: 200)

            VStack(alignment: .leading, spacing: 10) {
                if selected != nil {
                    TextField("Template name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.nutola(13, .medium))
                    TextEditor(text: $draftBody)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    Text("Placeholders: {{title}} {{date}} {{attendees}} {{duration}} {{app}} — headings guide the AI; text under a heading tells it what belongs there.")
                        .font(.nutola(10))
                        .foregroundStyle(.secondary)
                    HStack {
                        if let saveError {
                            Label(saveError, systemImage: "exclamationmark.triangle")
                                .font(.nutola(11))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button {
                            aiError = nil; showAISheet = true
                        } label: {
                            Label("Generate with AI", systemImage: "sparkles")
                                .font(.nutola(12, .medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(actionColor)
                        .help("Generate a new template with AI")
                        Button("Save") { save() }
                            .buttonStyle(.borderedProminent)
                            .tint(actionColor)
                            .disabled(!TemplateStore.isValid(name: draftName))
                    }
                } else {
                    EmptyStateView(
                        title: "Templates",
                        message: "Pick a template to edit, or add one. Templates shape every summary Nutola writes.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reload(select: selected ?? templates.first?.name) }
        .onChange(of: selected) { loadDraft() }
        .sheet(isPresented: $showAISheet) {
            aiTemplateSheet
        }
    }

    private var aiTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Generate Template with AI")
                    .font(.nutola(15, .bold))
                Spacer()
                Button("Cancel") { showAISheet = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Describe what kind of meeting template you need:")
                .font(.nutola(12))
                .foregroundStyle(.secondary)
            TextEditor(text: $aiPrompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 80)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            Text("Available placeholders: {{title}} {{date}} {{attendees}} {{duration}} {{app}}")
                .font(.nutola(10))
                .foregroundStyle(.secondary)
            HStack {
                if let aiError {
                    Label(aiError, systemImage: "exclamationmark.triangle")
                        .font(.nutola(11))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(isGenerating ? "Generating…" : "Generate") {
                    generateTemplate()
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                .disabled(isGenerating || aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func generateTemplate() {
        let promptText = aiPrompt.trimmingCharacters(in: .whitespaces)
        guard !promptText.isEmpty else { return }
        aiError = nil
        isGenerating = true
        let prompt = """
        Create a meeting notes template in Markdown. \(promptText)
        Use these placeholders: {{title}} {{date}} {{attendees}} {{duration}} {{app}}.
        Use ## headings to guide the AI summarizer — text under a heading tells it what belongs there.
        Return ONLY the markdown template, no explanation.
        """
        Task {
            do {
                let result = try await AIAsk.answer(prompt: prompt)
                // Sanitize the prompt into a valid template name — TemplateStore
                // rejects "/" and ":" (used as path separators), and we prefix
                // with "AI " so generated templates group together in the list.
                var raw = String(promptText.prefix(40)).trimmingCharacters(in: .whitespaces)
                raw = raw.replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "\n", with: " ")
                let baseName = raw.isEmpty ? "AI Template" : "AI - \(raw)"
                let finalName = nextUniqueTemplateName(baseName)
                try app.templates.save(SummaryTemplate(name: finalName, body: result))
                await MainActor.run {
                    isGenerating = false
                    showAISheet = false
                    aiPrompt = ""
                    reload(select: finalName)
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    aiError = error.localizedDescription
                }
            }
        }
    }

    /// Returns `baseName`, or `baseName 2`, `baseName 3`, … — whatever isn't
    /// already in `templates`. Avoids TemplateError.nameTaken on AI generation.
    private func nextUniqueTemplateName(_ baseName: String) -> String {
        let existing = Set(templates.map { $0.name.lowercased() })
        guard existing.contains(baseName.lowercased()) else { return baseName }
        var n = 2
        while existing.contains("\(baseName) \(n)".lowercased()) { n += 1 }
        return "\(baseName) \(n)"
    }

    private func reload(select: String?) {
        templates = app.templates.list()
        selected = select ?? templates.first?.name
        loadDraft()
    }

    private func loadDraft() {
        saveError = nil // don't carry a rename error onto another template
        guard let selected, let t = templates.first(where: { $0.name == selected }) else {
            draftName = ""; draftBody = ""
            return
        }
        draftName = t.name
        draftBody = t.body
    }

    private func save() {
        guard let selected else { return }
        let newName = draftName.trimmingCharacters(in: .whitespaces)
        do {
            try app.templates.rename(from: selected, to: newName, body: draftBody)
            saveError = nil
            reload(select: newName)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.appearanceMode) private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.actionColorHex) private var actionColorHex = Theme.defaultActionColorHex

    private var baseActionColor: Color {
        Color(hex: actionColorHex) ?? Theme.mediumGreen
    }

    private var actionColor: Color {
        Theme.prominentAction(baseActionColor, scheme: scheme)
    }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Choose light or dark mode, or follow your Mac's system setting.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }

            Section("Action color") {
                HStack {
                    Button("Record") {}
                        .buttonStyle(.borderedProminent)
                        .tint(actionColor)
                        .allowsHitTesting(false)
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 10) {
                    ForEach(ActionColorPreset.allCases) { preset in
                        Button {
                            actionColorHex = preset.rawValue
                        } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if actionColorHex.uppercased() == preset.rawValue {
                                        Circle().strokeBorder(Color.primary, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }

                ColorPicker("Custom color", selection: Binding(
                    get: { actionColor },
                    set: { newColor in
                        if let hex = newColor.hexString {
                            actionColorHex = hex
                        }
                    }
                ))
                if actionColorHex != Theme.defaultActionColorHex {
                    HStack {
                        Spacer()
                        Button("Reset to default") {
                            actionColorHex = Theme.defaultActionColorHex
                        }
                        .controlSize(.small)
                        .help("Reset the action color to the default Medium green")
                    }
                }
                Text("Used for Record, Save, and other prominent buttons. Adjusted automatically for readable labels in each theme.")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DebugSettings: View {
    var body: some View {
        Form {
            Section("Crashes") {
                CrashHistoryPanel()
            }
            Section("Logs") {
                AIDebugLogPanel()
                    .frame(minHeight: 320)
                HStack {
                    Text("Persisted logs are at ~/Library/Application Support/Nutola/Logs")
                        .font(.nutola(11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Export Logs") { exportLogs() }
                        .buttonStyle(.plain)
                        .font(.nutola(11))
                        .foregroundStyle(Theme.blueberry)
                    Button("Reveal in Finder") { revealLogs() }
                        .buttonStyle(.plain)
                        .font(.nutola(11))
                        .foregroundStyle(Theme.blueberry)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportLogs() {
        let text = NutolaFileLog.exportAll()
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nutola-logs-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([NutolaFileLog.logDirectoryURL])
    }
}

struct StatusDot: View {
    /// true = green, false = orange, nil = neutral (informational).
    let ok: Bool?

    init(ok: Bool?) { self.ok = ok }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .padding(.top, 3)
    }

    private var color: Color {
        switch ok {
        case .some(true): Theme.mint
        case .some(false): Color.orange
        case .none: Color.secondary.opacity(0.4)
        }
    }
}
