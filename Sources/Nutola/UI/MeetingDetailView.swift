import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    @State private var meeting: Meeting
    @State private var panelMode: GranolaPanelMode?
    @State private var title: String
    @State private var publishState: PublishState = .idle
    @State private var showDeleteConfirm = false
    @State private var notesDraft: String?
    @State private var transcriptDraft: String?
    @State private var showAttendees = false
    @State private var sideNotes = ""
    @State private var showSideNotes = false
    @State private var sideNotesSaveTask: Task<Void, Never>?
    @State private var decisionsExpanded = true
    @State private var showShareNotes = false
    @State private var showDevelopmentTasks = false
    @State private var shareNotesState: ShareNotesState = .idle
    @AppStorage(SettingsKey.sideNotesPanelWidth) private var sideNotesWidth = 280.0

    var backTitle: String?
    var onBack: (() -> Void)?

    enum PublishState: Equatable {
        case idle, working
        case done(URL)
        case failed(String)
    }

    enum ShareNotesState: Equatable {
        case idle, working
        case done
        case failed(String)
    }

    init(meeting: Meeting, backTitle: String? = nil, onBack: (() -> Void)? = nil) {
        _meeting = State(initialValue: meeting)
        _title = State(initialValue: meeting.title)
        self.backTitle = backTitle
        self.onBack = onBack
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: 0) {
                if showSideNotes {
                    SideNotesPanel(
                        text: $sideNotes,
                        isRecording: isRecordingThisMeeting,
                        onTextChange: scheduleSideNotesSave)
                        .frame(width: sideNotesWidth)

                    SideNotesResizeHandle(width: $sideNotesWidth)
                }

                VStack(spacing: 0) {
                    topChrome
                    documentScroll
                }
            }

            GranolaFloatingPanel(
                meeting: meeting,
                mode: $panelMode,
                transcriptDraft: $transcriptDraft)
        }
        .background(Theme.surface(scheme))
        .safeAreaInset(edge: .bottom) {
            if showProminentJoinButton, let join = joinConference {
                VStack(spacing: 8) {
                    if canContinueRecording {
                        HStack {
                            Spacer()
                            Button {
                                Task { await app.continueRecording(meetingID: meeting.id) }
                            } label: {
                                Label("Resume recording", systemImage: "mic.fill")
                                    .font(.nutola(11, .semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.mint(scheme))
                            .clipShape(Capsule())
                            Spacer()
                        }
                    }
                    ConferenceJoinButton(label: join.label, url: join.url, prominent: true, calendarEvent: linkedCalendarEvent)
                        .frame(maxWidth: 560)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .task { await app.calendar.refreshAgenda() }
        .onAppear {
            loadSideNotes()
            presentTranscriptIfNeeded()
        }
        .onDisappear { showAttendees = false }
        .onChange(of: app.store.meetings) {
            if let fresh = app.store.meetings.first(where: { $0.id == meeting.id }) {
                meeting = fresh
                if !isEditingTitle { title = fresh.title }
            }
        }
        .onChange(of: app.session?.meetingID) { _, id in
            if id == meeting.id {
                panelMode = .transcript
                showSideNotes = true
            }
        }
        .confirmationDialog("Move “\(meeting.title)” to trash?", isPresented: $showDeleteConfirm) {
            Button("Move to trash", role: .destructive) { app.store.delete(id: meeting.id) }
                .tint(.red)
        } message: {
            Text("This permanently removes the audio, transcript, and notes from your Mac.")
        }
        .sheet(isPresented: $showShareNotes) {
            shareNotesSheet
        }
        .sheet(isPresented: $showDevelopmentTasks) {
            DevelopmentTasksSheet(meeting: meeting)
        }
    }

    private var isRecordingThisMeeting: Bool {
        app.session?.meetingID == meeting.id
    }

    private var isPrepMeeting: Bool {
        meeting.state == .prep && !isRecordingThisMeeting
    }

    private var hasSideNotes: Bool {
        !sideNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadSideNotes() {
        sideNotes = app.store.sideNotes(for: meeting.id)
        showSideNotes = isRecordingThisMeeting || isPrepMeeting || hasSideNotes
    }

    private func scheduleSideNotesSave() {
        sideNotesSaveTask?.cancel()
        let text = sideNotes
        let id = meeting.id
        sideNotesSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            app.store.saveSideNotes(text, for: id)
        }
    }

    // MARK: - Chrome

    private var topChrome: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(backTitle ?? "Back")
                            .font(.nutola(13, .medium))
                    }
                    .foregroundStyle(Theme.secondary(scheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if case .done = publishState {
                GranolaChip(icon: "checkmark.circle.fill", text: "Shared", accent: Theme.mint(scheme))
            }
            Button {
                showDevelopmentTasks = true
            } label: {
                Label("Development tasks", systemImage: "checklist")
            }
            .buttonStyle(.borderless)
            .disabled(isRecordingThisMeeting || meeting.state == .processing)
            Button {
                copyTranscript()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
            .disabled(app.store.transcript(for: meeting.id).isEmpty)
            Button {
                showShareNotes = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .buttonStyle(.plain)
            .help("Share notes")
            publishMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var shouldCenterEmptyNotes: Bool {
        !isRecordingThisMeeting
            && !isPrepMeeting
            && notesDraft == nil
            && displayed.isEmpty
            && (showSideNotes || !hasSideNotes)
    }

    private var documentScroll: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 20) {
                    documentHeader
                    notesSection
                    decisionsSection
                    transcriptSection
                }
                .contentColumn()
                .frame(minHeight: shouldCenterEmptyNotes ? geo.size.height : nil, alignment: .top)
                .padding(.horizontal, 28)
                .padding(.bottom, panelMode != nil ? 340 : 100)
            }
        }
    }

    // MARK: - Document header

    @FocusState private var isEditingTitle: Bool

    private var documentHeader: some View {
        VStack(spacing: 14) {
            TextField("Meeting title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.granolaTitle(30))
                .foregroundStyle(Theme.heading(scheme))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .focused($isEditingTitle)
                .onSubmit(saveTitle)
                .onChange(of: isEditingTitle) { if !isEditingTitle { saveTitle() } }

            metadataChips
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            Button { showSideNotes.toggle() } label: {
                GranolaChip(
                    icon: "note.text",
                    text: hasSideNotes ? "My notes" : "Write notes",
                    accent: showSideNotes
                        ? Theme.mint(scheme)
                        : (isEmptyTranscriptNotice && !hasSideNotes ? Theme.honey(scheme) : actionColor))
            }
            .buttonStyle(.plain)
            .help(hasSideNotes ? "Show or hide your notes" : "Open notes to write what happened")

            if !summary.isEmpty {
                GranolaChip(icon: "sparkles", text: "Enhanced")
            }
            GranolaChip(
                icon: "calendar",
                text: meeting.createdAt.formatted(.dateTime.month(.abbreviated).day()))
            if meeting.duration > 0 {
                GranolaChip(
                    icon: "clock",
                    text: TemplateRenderer.duration(meeting.duration))
            }
            if let join = joinConference, !showProminentJoinButton {
                Button { ConferenceJoiner.open(join.url) } label: {
                    GranolaChip(
                        icon: "video.fill",
                        text: join.label,
                        accent: Theme.blueberry(scheme))
                }
                .buttonStyle(.plain)
            }
            if !meeting.attendees.isEmpty {
                Button { showAttendees = true } label: {
                    GranolaChip(
                        icon: "person.2",
                        text: attendeeChipLabel)
                }
                .buttonStyle(.plain)
                .help("Show all participants")
                .popover(isPresented: $showAttendees, arrowEdge: .top) {
                    attendeesPopover
                }
            }
            if let type = detectedMeetingType {
                GranolaChip(
                    icon: type.symbolName,
                    text: type.displayName,
                    accent: Theme.blueberry(scheme))
                    .help("Auto-detected meeting type. Template: \(MeetingTemplateResolver.templateName(for: type)).")
            }
            if let costChip = meetingCostChip {
                GranolaChip(
                    icon: nil,
                    text: "💰 \(costChip.formattedCost)",
                    accent: Theme.honey(scheme))
                .help("Estimated cost: \(costChip.attendeeCount) people × \(costChip.durationMinutes) min × \(MeetingCost.format(AppSettings.hourlyRatePerPerson))/hr")
            }
            folderChipContent
            if let provider = meeting.summaryProvider {
                providerChip(provider)
            }
            if let stage = app.processingStage[meeting.id] {
                GranolaChip(icon: nil, text: stage, accent: Theme.honey(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var folderChipContent: some View {
        if let folderID = meeting.folderID,
           let folder = app.folders.folder(id: folderID) {
            FolderPickerMenu(
                currentFolderID: folderID,
                calendarTitle: meeting.calendarEventTitle ?? meeting.title,
                meetingID: meeting.id
            ) {
                GranolaChip(icon: "folder", text: folder.name)
            }
            .buttonStyle(.plain)
        } else {
            FolderPickerMenu(
                currentFolderID: nil,
                calendarTitle: meeting.calendarEventTitle ?? meeting.title,
                meetingID: meeting.id
            ) {
                GranolaChip(icon: "folder.badge.plus", text: "Add to folder")
            }
            .buttonStyle(.plain)
        }
    }

    private var attendeesPopover: some View {
        ScrollView {
            FlowLayout(spacing: 6) {
                ForEach(meeting.attendees, id: \.self) { Chip(text: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 280, maxWidth: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerChip(_ provider: String) -> some View {
        let label: String
        switch provider {
        case "claude": label = "Claude"
        case "codex": label = "Codex"
        case "opencode": label = "OpenCode"
        case "vibe": label = "Mistral Vibe"
        case "apple": label = "Apple Intelligence"
        default: label = provider
        }
        return GranolaChip(icon: "sparkles", text: label, accent: Theme.raspberry)
    }

    // MARK: - Notes

    private var summary: String { app.store.summary(for: meeting.id) }
    private var streaming: String? { app.streamingSummaries[meeting.id] }
    private var displayed: String { streaming ?? summary }

    private var notesSection: some View {
        VStack(alignment: shouldCenterEmptyNotes ? .center : .leading, spacing: 12) {
            if isRecordingThisMeeting {
                if notesDraft != nil {
                    notesEditor
                } else if !displayed.isEmpty {
                    if !showSideNotes, hasSideNotes {
                        myNotesReader
                            .padding(.bottom, 16)
                    }
                    notesReader
                } else if streaming != nil || app.processingStage[meeting.id] != nil {
                    emptyNotes
                } else {
                    recordingPlaceholder
                }
            } else if isPrepMeeting {
                prepPlaceholder
            } else if notesDraft != nil {
                notesEditor
            } else if displayed.isEmpty {
                if !showSideNotes, hasSideNotes {
                    myNotesReader
                } else {
                    emptyNotes
                }
            } else {
                if !showSideNotes, hasSideNotes {
                    myNotesReader
                        .padding(.bottom, 16)
                }
                notesReader
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: shouldCenterEmptyNotes ? .infinity : nil,
            alignment: shouldCenterEmptyNotes ? .center : .leading)
    }

    // MARK: - Decisions

    /// Explicit decisions extracted from the transcript. Only rendered when the
    /// meeting is not being recorded live (decisions surface once a transcript is
    /// finalized) and at least one decision was found.
    @ViewBuilder
    private var decisionsSection: some View {
        if !decisions.isEmpty, !isRecordingThisMeeting {
            DisclosureGroup(isExpanded: $decisionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(decisions) { decision in
                        decisionCard(decision)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mint(scheme))
                    Text("Decisions")
                        .font(.nutola(12, .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                    Text("\(decisions.count)")
                        .font(.nutola(11, .semibold))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
            }
        }
    }

    private var decisions: [Decision] {
        DecisionExtractor.extract(
            from: app.store.transcript(for: meeting.id),
            speakers: meeting.speakers)
    }

    private func decisionCard(_ decision: Decision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(decision.speakerName)
                    .font(.nutola(11, .semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                Spacer(minLength: 0)
                Text(MeetingArchive.timestamp(decision.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiary(scheme))
            }
            Text(decision.quote)
                .font(.nutola(13))
                .foregroundStyle(Theme.heading(scheme))
                .textSelection(.enabled)
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(decision.speakerName) at \(MeetingArchive.timestamp(decision.timestamp)): \(decision.quote)")
    }

    // MARK: - Transcript

    /// Inline transcript empty-state. When the meeting has no transcript yet (and
    /// isn't being recorded live — the live transcript lives in the floating
    /// panel), show a placeholder so the document isn't silent about the missing
    /// transcript. When a transcript exists it's read via the floating Granola
    /// panel, so nothing renders inline here.
    @ViewBuilder
    private var transcriptSection: some View {
        if isRecordingThisMeeting || hasTranscript {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.tertiary(scheme))
                Text("No transcript yet")
                    .font(.nutola(13, .semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                Text(transcriptEmptyMessage)
                    .font(.nutola(11))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var transcriptEmptyMessage: String {
        if isPrepMeeting {
            return "The transcript will appear here once the meeting starts."
        }
        if meeting.duration > 0 {
            return "Nutola recorded this meeting but didn't capture speech. Check that microphone access is on."
        }
        return "Record this meeting to capture a transcript."
    }

    private var prepPlaceholder: some View {
        Text("Write notes")
            .font(.nutola(14))
            .foregroundStyle(Theme.tertiary(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 40)
    }

    private var recordingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSideNotes {
                Text("Enhanced notes will appear here as the meeting is summarized. The live transcript is in the Transcript panel below.")
                    .font(.nutola(13))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 40)
            } else {
                Text("Enhanced notes will appear here. Open My notes on the left, or use the Transcript panel below for the live transcript.")
                    .font(.nutola(14))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 40)
                    .onTapGesture { showSideNotes = true }
            }
        }
    }

    private var myNotesReader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My notes")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
            Text(sideNotes)
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    private var notesReader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let progress = app.summaryProgress[meeting.id] {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text(progress == .improving ? "Draft · improving" : "Writing…")
                            .font(.nutola(11))
                            .foregroundStyle(Theme.tertiary(scheme))
                    }
                }
                Spacer()
                notesEditMenu
            }
            .padding(.bottom, 8)

            if !displayed.isEmpty {
                Text("Enhanced notes")
                    .font(.nutola(12, .semibold))
                    .foregroundStyle(Theme.secondary(scheme))
                    .padding(.bottom, 8)
            }

            MarkdownText(markdown: displayed, style: .document)
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // TODO(localization): "Cancel" and "Save" below (and "Edit notes" in
            // notesEditMenu) are hardcoded English literals. SwiftPM has no
            // Localizable.xcstrings, so they aren't localized yet. When
            // localization lands, wrap them in LocalizedStringKey.
            HStack {
                Spacer()
                Button("Cancel") { notesDraft = nil }
                Button("Save") {
                    if let notesDraft { app.store.saveSummary(notesDraft, for: meeting.id) }
                    notesDraft = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
            }
            .controlSize(.small)

            TextEditor(text: Binding(get: { notesDraft ?? "" }, set: { notesDraft = $0 }))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200)
        }
    }

    @ViewBuilder
    private var emptyNotes: some View {
        if streaming != nil || app.processingStage[meeting.id] != nil {
            EmptyStateView(
                title: "Working on it…",
                message: app.processingStage[meeting.id] ?? "Writing your notes…")
        } else {
            EmptyStateView(
                title: emptyNotesTitle,
                message: emptyNotesMessage,
                // When resume is available, the action lives in the bottom
                // safeAreaInset — don't duplicate it here.
                actionTitle: canContinueRecording ? nil : emptyNotesActionTitle,
                actionIcon: canContinueRecording ? nil : emptyNotesActionIcon,
                action: canContinueRecording ? nil : emptyNotesAction,
                secondaryActionTitle: emptyNotesSecondaryActionTitle,
                secondaryAction: emptyNotesSecondaryAction,
                tips: emptyNotesTips)
        }
    }

    private var notesEditMenu: some View {
        Menu {
            Button {
                notesDraft = app.store.summary(for: meeting.id)
            } label: {
                Label("Edit notes", systemImage: "pencil")
            }
            .disabled(summary.isEmpty || streaming != nil)

            Menu("Regenerate") {
                ForEach(app.templates.list()) { template in
                    Button(template.name) {
                        Task {
                            await app.regenerateSummary(
                                meetingID: meeting.id, templateName: template.name)
                        }
                    }
                }
                Divider()
                Button("With current template") {
                    Task { await app.regenerateSummary(meetingID: meeting.id) }
                }
                if !regenerateProviderChoices.isEmpty {
                    Divider()
                    Menu("With another AI") {
                        ForEach(regenerateProviderChoices) { provider in
                            Button(provider.displayName) {
                                Task {
                                    await app.regenerateSummary(
                                        meetingID: meeting.id, forceProvider: provider)
                                }
                            }
                            .disabled(!provider.isAvailableForSummary)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiary(scheme))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var hasTranscript: Bool {
        !app.store.transcript(for: meeting.id).isEmpty
    }

    private var regenerateProviderChoices: [AIProvider] {
        AIProvider.allCases.filter { $0.rawValue != meeting.summaryProvider }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = meeting.notice,
           !isRecordingThisMeeting,
           !emptyNotesHandlesNotice,
           let presentation = MeetingNotice.effectivePresentation(
               for: notice, hasTranscript: hasTranscript) {
            MeetingNoticeBanner(
                presentation: presentation,
                primaryActionTitle: noticePrimaryActionTitle,
                primaryActionIcon: noticePrimaryActionIcon,
                primaryAction: noticePrimaryAction)
        } else if case .failed(let why) = publishState {
            MeetingNoticeBanner(
                presentation: MeetingNotice.Presentation(
                    title: "Couldn't publish",
                    message: why,
                    systemImage: "xmark.circle",
                    isEmptyTranscript: false))
        }
    }

    // MARK: - Helpers

    private var attendeeChipLabel: String {
        meeting.attendees.count == 1 ? "1 person" : "\(meeting.attendees.count) people"
    }
    /// Meeting-type badge for the header. Resolves the type from the calendar
    /// title + attendees (the transcript isn't available at header time) and
    /// returns it only when smart templates are on and the type is specific
    /// enough to be worth showing — `.generic` is suppressed so ordinary
    /// meetings don't get a noisy "General" chip.
    private var detectedMeetingType: MeetingType? {
        guard AppSettings.smartTemplatesEnabled else { return nil }
        let type = MeetingTemplateResolver.resolve(for: meeting)
        return type == .generic ? nil : type
    }
    /// Estimated-meeting-cost badge for the header. Non-nil only when the user
    /// has the cost feature on AND the meeting has both attendees and a recorded
    /// duration — otherwise the badge is suppressed (no attendees ⇒ no cost basis,
    /// zero duration ⇒ a $0 chip that just adds noise).
    private var meetingCostChip: MeetingCost? {
        guard AppSettings.showMeetingCost,
              !meeting.attendees.isEmpty,
              meeting.duration > 0 else { return nil }
        return MeetingCostCalculator.estimate(
            attendees: meeting.attendees,
            duration: meeting.duration,
            hourlyRatePerPerson: AppSettings.hourlyRatePerPerson)
    }

    /// Empty-state block already shows the notice and primary action — skip the banner.
    private var emptyNotesHandlesNotice: Bool {
        !isRecordingThisMeeting
            && !isPrepMeeting
            && displayed.isEmpty
            && streaming == nil
            && app.processingStage[meeting.id] == nil
            && noticePresentation != nil
    }

    private var emptyNotesTitle: String {
        noticePresentation?.title ?? "No notes yet"
    }

    private var emptyNotesMessage: String {
        if let presentation = noticePresentation {
            if presentation.isEmptyTranscript {
                if meeting.duration > 0 {
                    let duration = TemplateRenderer.duration(meeting.duration)
                    if hasSideNotes {
                        return "Nutola recorded \(duration) but didn't detect speech. Your notes are in My notes — resume recording if the call is still going."
                    }
                    return "Nutola recorded \(duration) but didn't detect speech. Resume if the meeting is still live, or write notes manually."
                }
                if hasSideNotes {
                    return "Nothing was transcribed, but you have notes in My notes. Resume recording if the call is still going."
                }
            }
            return presentation.message
        }
        return "Notes appear here once transcription finishes."
    }

    private var isEmptyTranscriptNotice: Bool {
        MeetingNotice.effectivePresentation(for: meeting.notice, hasTranscript: hasTranscript)?
            .isEmptyTranscript == true
    }

    private var noticePresentation: MeetingNotice.Presentation? {
        MeetingNotice.effectivePresentation(for: meeting.notice, hasTranscript: hasTranscript)
    }

    private var noticePrimaryActionTitle: String? {
        // When resume is available, the action lives in the bottom safeAreaInset.
        if canContinueRecording { return nil }
        if meeting.state == .failed { return "Retry" }
        if meeting.notice != nil { return "Regenerate" }
        return nil
    }

    private var noticePrimaryActionIcon: String? {
        // Resume icon lives in the bottom bar now; only show icons for other actions.
        canContinueRecording ? nil : (noticePrimaryActionTitle != nil ? "arrow.clockwise" : nil)
    }

    private var noticePrimaryAction: (() -> Void)? {
        if canContinueRecording { return nil }
        if meeting.state == .failed || meeting.notice != nil {
            return { Task { await app.retry(meetingID: meeting.id) } }
        }
        return nil
    }

    private var emptyNotesTips: [String] {
        guard isEmptyTranscriptNotice else { return [] }
        var tips: [String] = []
        if showProminentJoinButton, let join = joinConference {
            tips.append("Join \(join.label.replacingOccurrences(of: "Join ", with: "")) and resume recording to capture the call.")
        }
        if !hasSideNotes {
            tips.append("Use My notes to jot down what happened — they stay with this meeting.")
        }
        if meeting.displaySourceApp != nil {
            tips.append("Make sure Nutola has microphone and system audio access in Settings.")
        }
        return Array(tips.prefix(2))
    }

    private var emptyNotesActionTitle: String? {
        if canContinueRecording { return "Resume recording" }
        if meeting.state == .failed { return "Retry" }
        return nil
    }

    private var emptyNotesActionIcon: String? {
        emptyNotesActionTitle == "Resume recording" ? "mic.fill" : nil
    }

    private var emptyNotesSecondaryActionTitle: String? {
        if isEmptyTranscriptNotice {
            return showSideNotes ? nil : "Write notes"
        }
        if displayed.isEmpty, app.store.transcript(for: meeting.id).isEmpty {
            return "View transcript"
        }
        return nil
    }

    private var emptyNotesSecondaryAction: (() -> Void)? {
        if isEmptyTranscriptNotice, !showSideNotes {
            return { showSideNotes = true }
        }
        if displayed.isEmpty, app.store.transcript(for: meeting.id).isEmpty {
            return { panelMode = .transcript }
        }
        return nil
    }

    private func presentTranscriptIfNeeded() {
        guard panelMode == nil else { return }
        guard emptyNotesHandlesNotice, isEmptyTranscriptNotice else { return }
        guard app.store.transcript(for: meeting.id).isEmpty else { return }
        panelMode = .transcript
    }

    private var emptyNotesAction: (() -> Void)? {
        if canContinueRecording {
            return { Task { await app.continueRecording(meetingID: meeting.id) } }
        }
        if meeting.state == .failed {
            return { Task { await app.retry(meetingID: meeting.id) } }
        }
        return nil
    }

    private var canContinueRecording: Bool {
        meeting.canContinueRecording(isRecording: app.isRecording)
    }

    private var eventHasEnded: Bool {
        if let end = meeting.calendarEventEnd ?? linkedCalendarEvent?.end {
            return end < .now
        }
        return meeting.duration > 0 && (meeting.state == .ready || meeting.state == .failed)
    }

    private var showProminentJoinButton: Bool {
        joinConference != nil && !eventHasEnded
    }

    private var linkedCalendarEvent: CalendarEventSummary? {
        guard let id = meeting.calendarEventID else { return nil }
        return app.calendar.event(id: id, start: meeting.calendarEventStart)
    }

    private var joinConference: (label: String, url: URL)? {
        guard let event = linkedCalendarEvent,
              let url = event.conferenceURL else { return nil }
        let peers = app.calendar.agenda.flatMap(\.events)
        guard event.shouldShowJoinButton(among: peers) else { return nil }
        return (event.joinLabel, url)
    }

    private var publishMenu: some View {
        Menu {
            Button("Copy notes") { copyNotes() }
            Button("Preview in browser") { previewInBrowser() }
            Divider()
            Menu("Export…") {
                Button("HTML…") { exportHTML() }
                Button("PDF…") { exportPDF() }
                Button("Markdown…") { exportMarkdown() }
                Button("Subtitles (.srt)…") { exportSRT() }
                Button("Subtitles (.vtt)…") { exportVTT() }
                Divider()
                Button("CSV (all meetings)…") { exportCSVAll() }
                    .disabled(app.store.meetings.isEmpty)
            }
            FolderPickerMenu(
                currentFolderID: meeting.folderID,
                calendarTitle: meeting.calendarEventTitle ?? meeting.title,
                meetingID: meeting.id
            ) {
                Text("Move to folder…")
            }
            Button("Show files in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [app.store.archive.folder(for: meeting.id)])
            }
            Divider()
            Button("Move to trash", role: .destructive) { showDeleteConfirm = true }
        } label: {
            if publishState == .working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary(scheme))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func saveTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != meeting.title else { return }
        var m = meeting
        m.title = t
        app.store.upsert(m)
    }

    private func copyNotes() {
        let text = app.store.summary(for: meeting.id)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyTranscript() {
        let segments = app.store.transcript(for: meeting.id)
        guard !segments.isEmpty else { return }
        let text = TranscriptFormatter.plainText(segments, speakers: meeting.speakers)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func publish() {
        publishState = .working
        let m = meeting
        let summary = app.store.summary(for: m.id)
        let segments = app.store.transcript(for: m.id)
        Task {
            do {
                let html = HTMLExporter.html(meeting: m, summaryMarkdown: summary, segments: segments)
                let (_, rendered) = try await GitHubGist.publish(
                    html: html,
                    filename: "meeting.html",
                    description: "Nutola meeting notes — \(m.title)")
                if var fresh = app.store.meeting(id: m.id) {
                    fresh.publishedURL = rendered.absoluteString
                    app.store.upsert(fresh)
                }
                publishState = .done(rendered)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rendered.absoluteString, forType: .string)
            } catch {
                publishState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Share Notes

    /// Sheet with three ways to share the read-only notes page: copy the HTML
    /// to the pasteboard, save it to disk via NSSavePanel, or publish a secret
    /// gist and reveal the rendered notes.nutola.to URL.
    private var shareNotesSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.nutola(16, .medium))
                        .foregroundStyle(actionColor)
                    Text("Share Notes")
                        .font(.nutola(18, .bold))
                        .foregroundStyle(Theme.heading(scheme))
                }
                Text("A read-only page with the summary, action items, and transcript.")
                    .font(.nutola(12))
                    .foregroundStyle(Theme.secondary(scheme))
            }

            // Action buttons as cards
            VStack(spacing: 10) {
                shareActionCard(
                    icon: "doc.on.doc",
                    title: "Copy HTML",
                    subtitle: "Copy to clipboard",
                    isPrimary: false
                ) { copyShareNotesHTML() }

                shareActionCard(
                    icon: "square.and.arrow.down",
                    title: "Save HTML",
                    subtitle: "Save as a file",
                    isPrimary: false
                ) { saveShareNotesHTML() }


            }

            // Status
            switch shareNotesState {
            case .idle, .working:
                EmptyView()
            case .done:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.mint(scheme))
                    Text("HTML copied to clipboard!")
                        .font(.nutola(11, .medium))
                        .foregroundStyle(Theme.mint(scheme))
                    Spacer()
                }
                .padding(10)
                .background(Theme.mint(scheme).opacity(0.08),
                           in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .failed(let message):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.nutola(11))
                        .foregroundStyle(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08),
                           in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done") { showShareNotes = false }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(24)
        .frame(width: 440, height: 360)
        .onDisappear { shareNotesState = .idle }
    }

    private func shareActionCard(
        icon: String,
        title: String,
        subtitle: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.nutola(18, .medium))
                    .foregroundStyle(isPrimary ? .white : actionColor)
                    .frame(width: 36, height: 36)
                    .background(
                        isPrimary ? actionColor.opacity(0.15) : actionColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.nutola(13, .semibold))
                        .foregroundStyle(Theme.heading(scheme))
                    Text(subtitle)
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.nutola(10, .medium))
                    .foregroundStyle(Theme.tertiary(scheme))
            }
            .padding(12)
            .background(
                isPrimary
                    ? Theme.card(scheme)
                    : Theme.card(scheme).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isPrimary ? actionColor.opacity(0.2) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sharedNotesInputs() -> (Meeting, String, [TranscriptTurn], [ActionItem]) {
        let m = meeting
        let summary = app.store.summary(for: m.id)
        let turns = TranscriptTurnBuilder.turns(from: app.store.transcript(for: m.id))
        let items = ActionItemParser.parse(summary)
        return (m, summary, turns, items)
    }

    private func copyShareNotesHTML() {
        let (m, summary, turns, items) = sharedNotesInputs()
        let html = SharedNotesExporter.exportHTML(
            meeting: m, summary: summary, transcript: turns, actionItems: items)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .string)
        shareNotesState = .done
    }

    private func saveShareNotesHTML() {
        let (m, summary, turns, items) = sharedNotesInputs()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let html = SharedNotesExporter.exportHTML(
            meeting: m, summary: summary, transcript: turns, actionItems: items)
        try? html.data(using: .utf8)?.write(to: dest)
    }

    private func previewInBrowser() {
        let html = HTMLExporter.html(
            meeting: meeting,
            summaryMarkdown: app.store.summary(for: meeting.id),
            segments: app.store.transcript(for: meeting.id))
        let safeName = meeting.title.replacingOccurrences(of: "/", with: "-")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nutola — \(safeName).html")
        do {
            try html.data(using: .utf8)?.write(to: file)
            NSWorkspace.shared.open(file)
        } catch {
            publishState = .failed(error.localizedDescription)
        }
    }

    private func exportCSVAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Nutola meetings.csv"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let csv = CSVExporter.export(meetings: app.store.meetings)
        try? csv.data(using: .utf8)?.write(to: dest)
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let html = HTMLExporter.html(
            meeting: meeting,
            summaryMarkdown: app.store.summary(for: meeting.id),
            segments: app.store.transcript(for: meeting.id))
        try? html.data(using: .utf8)?.write(to: dest)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let md = TranscriptFormatter.markdown(
            app.store.transcript(for: meeting.id),
            speakers: meeting.speakers)
        try? md.data(using: .utf8)?.write(to: dest)
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename + ".srt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let srt = TranscriptFormatter.srt(
            app.store.transcript(for: meeting.id),
            speakers: meeting.speakers)
        try? srt.data(using: .utf8)?.write(to: dest)
    }

    private func exportVTT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename + ".vtt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let vtt = TranscriptFormatter.vtt(
            app.store.transcript(for: meeting.id),
            speakers: meeting.speakers)
        try? vtt.data(using: .utf8)?.write(to: dest)
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? PDFExporter.exportPDF(
            meeting: meeting,
            summaryMarkdown: app.store.summary(for: meeting.id),
            segments: app.store.transcript(for: meeting.id),
            to: dest)
    }

    private var safeFilename: String {
        meeting.title.replacingOccurrences(of: "/", with: "-")
    }
}
