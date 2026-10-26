import AppKit
import SwiftUI

// TODO(localization): The user-facing strings in this file ("Nutola", "Recording",
// "Stop & summarize", "Open Nutola", "Quit Nutola?", etc.) are hardcoded English.
// SwiftPM has no Localizable.xcstrings tooling, so they are not localized yet.
// When localization infrastructure is added, wrap each Text/Label literal in
// LocalizedStringKey and extract them via String(localized:).

struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor
    @State private var showQuitConfirm = false
    @State private var gearHovering = false
    @State private var powerHovering = false
    @StateObject private var archivedStore = ArchivedEventStore()


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let session = app.session {
                RecordingCard(session: session, meeting: app.recordingMeeting) {
                    app.openMeetingID = session.meetingID
                    openMain()
                }
            } else if let detected = app.detectedAppName {
                detectionBanner(detected)
            } else {
                let resumable = app.resumableMeeting
                Button {
                    dismissMenu()
                    Task {
                        if resumable != nil {
                            await app.resumeOrphanIfAny()
                        } else {
                            await app.startRecording()
                        }
                    }
                } label: {
                    Label(resumable != nil ? "Resume recording" : "Start recording",
                          systemImage: resumable != nil ? "play.circle" : "record.circle")
                        .font(.nutola(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(actionColor)
            }
            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.nutola(11))
                    .foregroundStyle(.orange)
            }
            upcoming
            recent
            Divider()
            if showQuitConfirm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quit Nutola?")
                        .font(.nutola(12, .semibold))
                        .foregroundStyle(Theme.heading(scheme))
                    Text(app.isRecording
                         ? "A recording is in progress."
                         : "Nutola will stop running in the background.")
                        .font(.nutola(10))
                        .foregroundStyle(Theme.secondary(scheme))
                    HStack {
                        Spacer()
                        Button("Cancel") { showQuitConfirm = false }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 4)
            } else {
                HStack {
                    Button("Open Nutola") { openMain() }
                        .buttonStyle(.plain)
                        .font(.nutola(12, .medium))
                        .foregroundStyle(Theme.blueberry)
                    Spacer()
                    Button {
                        showQuitConfirm = true
                    } label: {
                        Image(systemName: "power")
                            .font(.nutola(13, .medium))
                            .foregroundStyle(.red)
                            .frame(width: 30, height: 30)
                            .background(
                                powerHovering ? Color.red.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { powerHovering = $0 }
                    .help("Quit Nutola")
                    .accessibilityLabel("Quit Nutola")
                }
        }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        .frame(width: 320)
    }

    private var upcomingDays: [UpcomingMeetingsDay] {
        app.calendar.upcomingDays(limit: UpcomingMeetings.defaultLimit)
    }

    private var upcoming: some View {
        Group {
            if AppSettings.useCalendar, CalendarAuthorization.isAuthorized, !upcomingDays.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Coming up")
                        .font(.nutola(11, .semibold))
                        .foregroundStyle(.secondary)

                    if let first = upcomingDays.first?.events.first {
                        if first.isInProgress, let endsIn = app.calendar.endsInText(for: first) {
                            Text("Ends \(endsIn)")
                                .font(.nutola(11, .semibold))
                                .foregroundStyle(.secondary)
                        } else if let startsIn = app.calendar.startsInText(for: first) {
                            Text("Starts \(startsIn)")
                                .font(.nutola(11, .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Plain VStack — ScrollView collapses to zero height inside MenuBarExtra panels.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(upcomingDays) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                if day.label != "Today" {
                                    Text(day.label)
                                        .font(.nutola(11, .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, day.id == upcomingDays.first?.id ? 0 : 4)
                                }
                                ForEach(day.events, id: \.rowID) { event in
                                    upcomingRow(event, peers: day.events)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func upcomingRow(_ event: CalendarEventSummary, peers: [CalendarEventSummary]) -> some View {
        let showJoin = event.shouldShowJoinButton(among: peers)
        return HStack(alignment: .top, spacing: 6) {
            Button {
                dismissMenu()
                app.openCalendarEvent(event)
                openMain()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.nutola(12, .medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let countdown = app.calendar.countdownText(for: event) {
                                Text(countdown)
                                    .font(.nutola(10, .semibold))
                                    .foregroundStyle(event.isInProgress ? Theme.mint(scheme) : Theme.honey(scheme))
                            }
                            Text(CalendarTimeFormatter.timeRange(start: event.start, end: event.end))
                                .font(.nutola(10))
                                .foregroundStyle(Theme.secondary(scheme))
                        }
                        if let location = event.location {
                            Text(location)
                                .font(.nutola(9))
                                .foregroundStyle(Theme.tertiary(scheme))
                                .lineLimit(1)
                        }
                    }
                    .calendarEventIndicator(event.calendarColor.swiftUIColor)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .disabled(app.isRecording || event.isPast())
            .contextMenu {
                Button {
                    archivedStore.archiveTitle(event.title)
                    Task { await app.calendar.refreshAgenda() }
                } label: {
                    Label("Archive series", systemImage: "archivebox.fill")
                }
                Button {
                    archivedStore.archiveEvent(id: event.id, title: event.title)
                    Task { await app.calendar.refreshAgenda() }
                } label: {
                    Label("Archive this event", systemImage: "archivebox")
                }
            }

            if showJoin, let url = event.conferenceURL {
                ConferenceJoinButton(label: event.joinLabel, url: url, calendarEvent: event)
            } else if event.conferenceURL != nil {
                ConferenceVideoIcon()
                    .padding(.top, 1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NutolaStripes().scaleEffect(0.45).frame(width: 20, height: 26)
                .accessibilityLabel("Nutola")
                .accessibilityValue(menuBarStateValue)
            Text("Nutola")
                .font(.nutola(16, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Spacer()
            Button {
                dismissMenu()
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.nutola(14, .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        gearHovering ? Color.secondary.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { gearHovering = $0 }
            .help("Open Settings")
            .accessibilityLabel("Settings")
            .accessibilityHint("Open Nutola settings")
        }
    }

    /// Voice-over description of the current top-level state shown in the menu bar.
    private var menuBarStateValue: String {
        if app.isRecording { return "Recording" }
        if app.detectedAppName != nil { return "Meeting detected" }
        if app.resumableMeeting != nil { return "Recording can be resumed" }
        if let first = upcomingDays.first?.events.first, first.isInProgress {
            return "Meeting in progress"
        }
        return "Idle"
    }

    private func detectionBanner(_ appName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(appName) is using the microphone", systemImage: "waveform.badge.mic")
                .font(.nutola(12, .semibold))
            HStack {
                Button {
                    dismissMenu()
                    Task { await app.acceptDetection() }
                } label: {
                    Text("Record meeting").font(.nutola(12, .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                Button("Dismiss") { app.dismissDetection() }
                    .buttonStyle(.bordered)
                    .font(.nutola(12))
            }
        }
        .cardStyle()
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !app.store.meetings.isEmpty {
                Text("Recent")
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            ForEach(app.store.meetings.prefix(4)) { meeting in
                Button {
                    app.openMeetingID = meeting.id
                    openMain()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title)
                                .font(.nutola(12, .medium))
                                .lineLimit(1)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.nutola(10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StateBadge(meeting: meeting, stage: app.processingStage[meeting.id])
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    private func dismissMenu() {
        MenuBarExtraPanel.dismiss()
    }

    private func openMain() {
        dismissMenu()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftUI's MenuBarExtra(.window) has no dismiss API — capture the panel and
/// order it out. As a fallback, also try clicking the status bar item to
/// toggle the panel closed.
@MainActor
private enum MenuBarExtraPanel {
    private static weak var window: NSWindow?

    static func dismiss() {
        window?.orderOut(nil)
        // Also try close — some MenuBarExtra windows respond to this
        window?.close()
    }

    static func bind(_ window: NSWindow?) {
        Self.window = window
    }
}

private struct MenuBarExtraWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ nsView: HookView, context: Context) {}

    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MenuBarExtraPanel.bind(window)
        }
    }
}

private struct RecordingCard: View {
    @ObservedObject var session: RecordingSession
    let meeting: Meeting?
    /// Invoked when the title row is tapped — opens the live meeting in the main window.
    var onOpenMeeting: (() -> Void)? = nil
    @EnvironmentObject private var app: AppState
    @Environment(\.nutolaActionColor) private var actionColor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onOpenMeeting?()
            } label: {
                HStack {
                    RecordDot()
                    Text(meeting?.title ?? "Recording")
                        .font(.nutola(13, .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(timeString(session.elapsed))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(actionColor)
                }
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenMeeting == nil)
            .help(onOpenMeeting != nil ? "Open live transcript" : "")
            if let notice = session.speakerTrackingNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                LevelMeter(levels: session.micBarLevels)
                Spacer()
                if !session.systemStarted {
                    Text("mic only")
                        .font(.nutola(10))
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Button {
                    Task { await app.stopRecording() }
                } label: {
                    Label("Stop & summarize", systemImage: "stop.fill")
                        .font(.nutola(12, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                Button {
                    app.discardRecording()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Discard this recording")
                .accessibilityLabel("Discard recording")
                .accessibilityHint("Deletes the current recording and its transcript without saving")
            }
            if app.showLiveRecordingCard, app.recordingCardDismissed {
                Button {
                    app.recordingCardDismissed = false
                } label: {
                    Label("Show live transcript card", systemImage: "rectangle.on.rectangle")
                        .font(.nutola(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blueberry)
            } else if app.showLiveRecordingCard, app.recordingCardMinimized {
                Button {
                    app.recordingCardMinimized = false
                } label: {
                    Label("Expand live transcript card", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.nutola(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blueberry)
            }
        }
        .cardStyle()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
