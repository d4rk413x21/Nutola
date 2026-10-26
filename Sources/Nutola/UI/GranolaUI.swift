import AppKit
import SwiftUI

// MARK: - Metadata chips

struct GranolaChip: View {
  @Environment(\.colorScheme) private var scheme
  let icon: String?
  let text: String
  var accent: Color?

  var body: some View {
    HStack(spacing: 5) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .accessibilityHidden(true)
      }
      Text(text)
        .font(.nutola(11, .medium))
        .lineLimit(1)
    }
    .foregroundStyle(accent ?? Theme.secondary(scheme))
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Theme.chip(scheme), in: Capsule())
    .overlay {
      Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Floating panel

enum GranolaPanelMode: Equatable {
  case transcript
  case ask
}

struct GranolaFloatingPanel: View {
  @EnvironmentObject private var app: AppState
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.nutolaActionColor) private var actionColor

  let meeting: Meeting
  @Binding var mode: GranolaPanelMode?
  @Binding var transcriptDraft: String?

  @State private var askInput = ""
  @State private var askAvailable = false
  @State private var transcriptSearch = ""
  @State private var isTranscriptSearchPresented = false
  @State private var showAskSheet = false
  @State private var askSheetQuestion: String?
  @FocusState private var transcriptSearchFocused: Bool
  @AppStorage(SettingsKey.preferredAIProvider) private var preferredAIProvider: AIProvider = .apple
  @AppStorage(SettingsKey.askDeliveryMode) private var askDeliveryMode: AskDeliveryMode = .cli

  private var isExpanded: Bool { mode != nil }
  private var segments: [TranscriptSegment] { app.store.transcript(for: meeting.id) }
  private var isLive: Bool {
    app.session?.meetingID == meeting.id
  }

  private var isPrep: Bool {
    meeting.state == .prep && !isLive
  }

  private var summaryText: String { app.store.summary(for: meeting.id) }

  private var canAskAboutMeeting: Bool {
    askAvailable && (!segments.isEmpty || !summaryText.isEmpty)
  }

  private func refreshAskAvailability() {
    let provider = preferredAIProvider
    let mode = AppSettings.askDeliveryMode
    Task.detached {
      let available = AIAsk.isAvailable(for: mode, provider: provider)
      await MainActor.run { askAvailable = available }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if isExpanded {
        expandedContent
          .transition(.move(edge: .bottom).combined(with: .opacity))
      } else {
        collapsedBar
      }
    }
    .frame(maxWidth: 560)
    .floatingSurface(in: RoundedRectangle(cornerRadius: isExpanded ? 20 : 28), opaque: isExpanded)
    .padding(.horizontal, 24)
    .padding(.bottom, 16)
    // Respect "Reduce Motion": skip the spring when the user has it enabled.
    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: mode)
    .onAppear { refreshAskAvailability() }
    .onReceive(NotificationCenter.default.publisher(for: .nutolaCLIAvailabilityChanged)) { _ in
      refreshAskAvailability()
    }
    .onChange(of: preferredAIProvider) { refreshAskAvailability() }
    .onChange(of: askDeliveryMode) { refreshAskAvailability() }
    .onChange(of: mode) { _, newMode in
      if newMode != .transcript {
        transcriptSearch = ""
        isTranscriptSearchPresented = false
        transcriptSearchFocused = false
      }
    }
    .sheet(isPresented: $showAskSheet) {
      MeetingLauncherView(meeting: meeting, initialQuestion: askSheetQuestion)
        .frame(minWidth: 560, minHeight: 480)
    }
  }

  // MARK: Expanded body

  @ViewBuilder
  private var expandedContent: some View {
    switch mode {
    case .transcript:
      transcriptBody
    case .ask:
      askBody
    case nil:
      EmptyView()
    }
  }

  private var transcriptBody: some View {
    VStack(spacing: 0) {
      transcriptHeader

      if isLive, let session = app.session {
        GranolaLiveTranscriptContent(
          session: session,
          priorSegments: segments,
          speakers: meeting.speakers,
          searchQuery: transcriptSearch
        )
        .frame(height: 260)
      } else if segments.isEmpty {
        transcriptEmptyState
          .frame(maxWidth: .infinity, minHeight: 120)
          .padding(20)
      } else {
        GranolaTranscriptContent(
          meeting: meeting,
          segments: segments,
          draft: $transcriptDraft,
          searchQuery: transcriptSearch
        )
        .frame(height: 260)
      }

      if meeting.platformSpeakerAttribution {
        Text("Speaker identification is in beta and may not always be accurate.")
          .font(.nutola(10))
          .foregroundStyle(Theme.tertiary(scheme))
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 16)
          .padding(.bottom, 4)
      }

      transcriptFooter
    }
  }

  @ViewBuilder
  private var transcriptEmptyState: some View {
    if isPrep {
      Text("Transcript Paused")
        .font(.nutola(12))
        .foregroundStyle(Theme.secondary(scheme))
    } else if meeting.notice != nil {
      VStack(spacing: 8) {
        Image(systemName: "waveform.slash")
          .font(.system(size: 22, weight: .light))
          .foregroundStyle(Theme.tertiary(scheme))
        Text("No transcript")
          .font(.nutola(12, .semibold))
          .foregroundStyle(Theme.secondary(scheme))
        if meeting.duration > 0 {
          Text("Recorded \(TemplateRenderer.duration(meeting.duration)) — no speech detected.")
            .font(.nutola(11))
            .foregroundStyle(Theme.tertiary(scheme))
            .multilineTextAlignment(.center)
        } else {
          Text("Nothing was captured during this recording.")
            .font(.nutola(11))
            .foregroundStyle(Theme.tertiary(scheme))
            .multilineTextAlignment(.center)
        }
      }
    } else {
      Text("No transcript yet.")
        .font(.nutola(12))
        .foregroundStyle(Theme.secondary(scheme))
    }
  }

  private var transcriptHeader: some View {
    let searching = isTranscriptSearchPresented || !transcriptSearch.isEmpty

    return HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12, weight: searching ? .semibold : .regular))
          .foregroundStyle(searching ? Theme.mint(scheme) : Theme.secondary(scheme))

        if searching {
          TextField("Search transcript…", text: $transcriptSearch)
            .textFieldStyle(.plain)
            .font(.nutola(12))
            .focused($transcriptSearchFocused)
            .onAppear { focusTranscriptSearch() }
            .onChange(of: transcriptSearchFocused) { _, focused in
              if !focused, transcriptSearch.isEmpty {
                isTranscriptSearchPresented = false
              }
            }

          if !transcriptSearch.isEmpty {
            Button {
              transcriptSearch = ""
              focusTranscriptSearch()
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary(scheme))
            }
            .buttonStyle(.plain)
            .help("Clear search")
            .accessibilityLabel("Clear search")
          }
        } else {
          Button("Transcript", action: presentTranscriptSearch)
            .buttonStyle(.plain)
            .accessibilityLabel("Search transcript")
            .font(.nutola(12, .semibold))
            .foregroundStyle(Theme.secondary(scheme))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .help(searching ? "Search transcript" : "Search transcript (click to open)")

      if isLive, let session = app.session {
        LiveLocaleMenu(session: session, store: app.localeOverrides)
      }
      if isLive || !segments.isEmpty {
        Button {
          copyTranscript()
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary(scheme))
        }
        .buttonStyle(.plain)
        .help("Copy transcript")
        .accessibilityLabel("Copy transcript")
      }
      collapseButton
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) { Divider().opacity(0.3) }
  }

  /// Copies the full transcript to the pasteboard — both prior (finalized)
  /// and live segments, formatted as "Speaker: text" lines.
  private func copyTranscript() {
    let session = app.session
    let text = TranscriptFormatter.clipboardText(
      meeting: meeting, saved: segments, liveMeetingID: session?.meetingID,
      live: session?.liveSegments ?? [],
      localName: LiveTranscriber.localSpeakerName, remoteName: LiveTranscriber.remoteSpeakerName)
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func presentTranscriptSearch() {
    isTranscriptSearchPresented = true
    focusTranscriptSearch()
  }

  private func focusTranscriptSearch() {
    DispatchQueue.main.async {
      transcriptSearchFocused = true
    }
  }

  private var askBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      panelHeader(
        leading: {
          if !askInput.isEmpty {
            Button {
              askInput = ""
            } label: {
              Label("Clear", systemImage: "xmark.circle")
                .font(.nutola(11, .medium))
                .foregroundStyle(Theme.tertiary(scheme))
            }
            .buttonStyle(.plain)
            .help("Clear the question")
            .accessibilityLabel("Clear the question")
          }
        }, title: nil)

      if canAskAboutMeeting {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(MeetingAISuggestions.forMeeting(meeting), id: \.self) { suggestion in
            Button {
              launchAsk(suggestion)
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "square")
                  .font(.system(size: 11))
                  .foregroundStyle(Theme.tertiary(scheme))
                Text(suggestion)
                  .font(.nutola(13))
                  .foregroundStyle(Theme.heading(scheme))
                Spacer()
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 8)
      } else {
        Text(
          "Record the meeting or add notes first — then you can ask questions about what happened."
        )
        .font(.nutola(12))
        .foregroundStyle(Theme.secondary(scheme))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
      }

      askInputBar
    }
  }

  // MARK: Collapsed bar

  private var collapsedBar: some View {
    Group {
      if isPrep {
        prepCollapsedBar
      } else {
        activeCollapsedBar
      }
    }
  }

  private var activeCollapsedBar: some View {
    HStack(spacing: 12) {
      transcriptToggle

      Button {
        askSheetQuestion = nil
        showAskSheet = true
      } label: {
        Text(canAskAboutMeeting ? "Ask anything" : "Ask (needs transcript)")
          .font(.nutola(13))
          .foregroundStyle(
            canAskAboutMeeting ? Theme.tertiary(scheme) : Theme.tertiary(scheme).opacity(0.55)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .disabled(!canAskAboutMeeting)
      .help(
        canAskAboutMeeting
          ? "Ask questions about this meeting"
          : "Record or add notes before asking questions"
      )
      .accessibilityAddTraits(.isButton)
      .accessibilityAddTraits(mode == .ask ? .isSelected : [])

      if showCollapsedResume {
        Button {
          Task { await app.continueRecording(meetingID: meeting.id) }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "mic.fill")
              .font(.system(size: 10, weight: .semibold))
            Text("Resume")
              .font(.nutola(11, .semibold))
          }
          .foregroundStyle(Theme.mint(scheme))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var prepCollapsedBar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "waveform")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.tertiary(scheme))

        Text("Transcript Paused")
          .font(.nutola(13))
          .foregroundStyle(Theme.tertiary(scheme))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      HStack(spacing: 12) {
        if let start = meeting.calendarEventStart, start > .now {
          Text("Starts \(CalendarTimeFormatter.time(start))")
            .font(.nutola(12, .medium))
            .foregroundStyle(Theme.secondary(scheme))
        }

        Button {
          Task { await app.continueRecording(meetingID: meeting.id) }
        } label: {
          Text("Start now")
            .font(.nutola(12, .semibold))
            .foregroundStyle(Theme.honey(scheme))
        }
        .buttonStyle(.plain)
        .disabled(app.isRecording)

        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .overlay(alignment: .top) { Divider().opacity(0.3) }
    }
  }

  private var canContinueRecording: Bool {
    meeting.canContinueRecording(isRecording: app.isRecording)
  }

  /// Resume lives in the empty-state hero when notes are still blank.
  private var showCollapsedResume: Bool {
    guard canContinueRecording else { return false }
    let summaryEmpty =
      app.store.summary(for: meeting.id).isEmpty
      && app.streamingSummaries[meeting.id] == nil
    return !summaryEmpty
  }

  private var transcriptToggle: some View {
    Button {
      mode = mode == .transcript ? nil : .transcript
    } label: {
      HStack(spacing: 6) {
        // Icon signals the listening state beyond color: waveform while
        // the transcript is open, a resting moon when idle.
        Image(systemName: mode == .transcript ? "waveform" : "moon.zzz")
          .font(.system(size: 11, weight: .semibold))
        Text("Transcript")
          .font(.nutola(12, .medium))
      }
      .foregroundStyle(mode == .transcript ? Theme.mint(scheme) : Theme.secondary(scheme))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(mode == .transcript ? .isSelected : [])
  }

  private var collapseButton: some View {
    Button {
      mode = nil
    } label: {
      Image(systemName: "chevron.down")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.tertiary(scheme))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, -12)
    .help("Collapse panel")
    .accessibilityLabel("Collapse panel")
  }

  private var askInputBar: some View {
    HStack(spacing: 10) {
      TextField("Ask anything", text: $askInput)
        .textFieldStyle(.plain)
        .font(.nutola(13))
        .disabled(!canAskAboutMeeting)
        .onSubmit { launchTypedAsk() }

      Text(preferredAIProvider.displayName)
        .font(.nutola(10, .medium))
        .foregroundStyle(Theme.tertiary(scheme))

      Button(action: launchTypedAsk) {
        Image(systemName: "arrow.up")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(
            Circle().fill(
              canAskAboutMeeting
                && !askInput.trimmingCharacters(in: .whitespaces).isEmpty
                ? actionColor
                : Color.secondary.opacity(0.25))
          )
      }
      .buttonStyle(.plain)
      .disabled(!canAskAboutMeeting || askInput.trimmingCharacters(in: .whitespaces).isEmpty)
      .accessibilityLabel("Send question")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Theme.chip(scheme), in: Capsule())
    .overlay {
      Capsule().strokeBorder(Theme.mint(scheme).opacity(0.35), lineWidth: 1)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  @ViewBuilder
  private var transcriptFooter: some View {
    HStack(spacing: 12) {
      if isPrep {
        if let start = meeting.calendarEventStart, start > .now {
          Text("Starts \(CalendarTimeFormatter.time(start))")
            .font(.nutola(12, .medium))
            .foregroundStyle(Theme.secondary(scheme))
        }
        Button {
          Task { await app.continueRecording(meetingID: meeting.id) }
        } label: {
          Text("Start now")
            .font(.nutola(12, .semibold))
            .foregroundStyle(Theme.honey(scheme))
        }
        .buttonStyle(.plain)
        .disabled(app.isRecording)
      } else if meeting.canContinueRecording(isRecording: app.isRecording) {
        Button {
          Task { await app.continueRecording(meetingID: meeting.id) }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "mic.fill")
              .font(.system(size: 11, weight: .semibold))
            Text("Resume recording")
              .font(.nutola(12, .semibold))
          }
          .foregroundStyle(Theme.mint(scheme))
        }
        .buttonStyle(.plain)
      } else if isLive {
        Button {
          Task { await app.stopRecording() }
        } label: {
          HStack(spacing: 6) {
            RecordDot()
            Text("Stop")
              .font(.nutola(12, .semibold))
          }
          .foregroundStyle(actionColor)
        }
        .buttonStyle(.plain)
      }

      Spacer()

      if isLive {
        Label("Live", systemImage: "circle.fill")
          .font(.nutola(10, .medium))
          .foregroundStyle(Theme.mint(scheme))
          .labelStyle(.titleAndIcon)
          .symbolRenderingMode(.palette)
          .foregroundStyle(Theme.mint(scheme), Theme.mint(scheme).opacity(0.3))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .overlay(alignment: .top) { Divider().opacity(0.3) }
  }

  private func panelHeader<Leading: View>(
    @ViewBuilder leading: () -> Leading = { EmptyView() },
    title: String?
  ) -> some View {
    HStack(spacing: 8) {
      leading()
      if let title {
        Text(title)
          .font(.nutola(12, .semibold))
          .foregroundStyle(Theme.secondary(scheme))
      }
      Spacer()
      collapseButton
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) { Divider().opacity(0.3) }
  }

  private func launchTypedAsk() {
    let text = askInput.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    launchAsk(text)
  }

  private func launchAsk(_ question: String) {
    // Mirrors AILauncherView.submit: "Answer here" (CLI) streams in-app via the
    // Ask sheet; "Open in app" deep-links the external assistant. Apple
    // Intelligence is always CLI (on-device), so it routes through the sheet too.
    let effectiveMode: AskDeliveryMode = preferredAIProvider.supportsApp ? askDeliveryMode : .cli
    switch effectiveMode {
    case .cli:
      askSheetQuestion = question
      showAskSheet = true
    case .app:
      let prompt: String
      switch preferredAIProvider {
      case .apple, .opencode, .vibe:
        return
      case .claude:
        prompt = ClaudeDesktopPrompt.meeting(
          id: meeting.id, title: meeting.title, question: question)
      case .codex:
        prompt = CodexPrompt.meeting(
          id: meeting.id, title: meeting.title, question: question)
      }
      _ = AIAsk.open(prompt: prompt)
    }
    askInput = ""
  }
}

// MARK: - Transcript content (chat bubbles)

struct GranolaTranscriptContent: View {
  @EnvironmentObject private var app: AppState
  @Environment(\.colorScheme) private var scheme
  @Environment(\.nutolaActionColor) private var actionColor

  let meeting: Meeting
  let segments: [TranscriptSegment]
  @Binding var draft: String?
  var searchQuery: String = ""

  private var turns: [TranscriptTurn] {
    TranscriptTurnBuilder.turns(from: segments)
  }

  private var filteredTurns: [TranscriptTurn] {
    TranscriptSearch.filter(turns, query: searchQuery)
  }

  private var isSearching: Bool {
    !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    if draft != nil {
      TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
        .font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(12)
    } else if isSearching, filteredTurns.isEmpty {
      Text("No matches for “\(searchQuery.trimmingCharacters(in: .whitespaces))”.")
        .font(.nutola(12))
        .foregroundStyle(Theme.secondary(scheme))
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(20)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(Array(filteredTurns.enumerated()), id: \.element.id) { index, turn in
              if shouldShowTimestamp(before: turn, at: index, in: filteredTurns) {
                Text(MeetingArchive.timestamp(turn.start))
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(Theme.tertiary(scheme))
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 4)
              }
              TranscriptBubble(
                turn: turn,
                isSelf: isSelf(turn.speakerID),
                speakerName: name(for: turn.speakerID),
                searchQuery: searchQuery
              )
              .id(turn.id)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
        }
        .onChange(of: searchQuery) {
          guard let first = filteredTurns.first else { return }
          proxy.scrollTo(first.id, anchor: .top)
        }
      }
    }
  }

  private func isSelf(_ speakerID: String) -> Bool {
    speakerID == LiveTranscriber.youSpeakerID
      || meeting.speakers.first(where: { $0.id == speakerID })?.isMe == true
  }

  private func name(for speakerID: String) -> String {
    meeting.speakers.first { $0.id == speakerID }?.name ?? speakerID
  }

  private func shouldShowTimestamp(
    before turn: TranscriptTurn, at index: Int, in turns: [TranscriptTurn]
  ) -> Bool {
    guard index > 0 else { return true }
    let prev = turns[index - 1]
    return turn.start - prev.end > 30
  }
}

struct GranolaLiveTranscriptContent: View {
  @ObservedObject var session: RecordingSession
  var priorSegments: [TranscriptSegment]
  var speakers: [Speaker]
  var searchQuery: String = ""

  @Environment(\.colorScheme) private var scheme

  private var priorTurns: [TranscriptTurn] {
    TranscriptTurnBuilder.turns(from: priorSegments)
  }

  private var liveTurns: [TranscriptTurn] {
    TranscriptTurnBuilder.turns(from: session.liveSegments)
  }

  private var filteredPriorTurns: [TranscriptTurn] {
    TranscriptSearch.filter(priorTurns, query: searchQuery)
  }

  private var filteredLiveTurns: [TranscriptTurn] {
    TranscriptSearch.filter(liveTurns, query: searchQuery)
  }

  private var isSearching: Bool {
    !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private var volatileMatchesSearch: Bool {
    guard isSearching else { return true }
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    return session.volatileText.localizedCaseInsensitiveContains(query)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 6) {
          if isSearching, filteredPriorTurns.isEmpty, filteredLiveTurns.isEmpty,
            !volatileMatchesSearch
          {
            Text("No matches for “\(searchQuery.trimmingCharacters(in: .whitespaces))”.")
              .font(.nutola(12))
              .foregroundStyle(Theme.secondary(scheme))
              .frame(maxWidth: .infinity, minHeight: 120)
              .padding(.vertical, 20)
          }

          ForEach(filteredPriorTurns) { turn in
            TranscriptBubble(
              turn: turn,
              isSelf: isSelf(turn.speakerID),
              speakerName: name(for: turn.speakerID),
              searchQuery: searchQuery)
          }

          ForEach(filteredLiveTurns) { turn in
            TranscriptBubble(
              turn: turn,
              isSelf: isSelf(turn.speakerID),
              speakerName: name(for: turn.speakerID),
              searchQuery: searchQuery)
          }

          if !session.volatileText.isEmpty, volatileMatchesSearch {
            HStack {
              if isSelf(LiveTranscriber.youSpeakerID) { Spacer(minLength: 48) }
              TranscriptSearch.highlightedText(
                session.volatileText,
                query: searchQuery,
                scheme: scheme
              )
              .font(.nutola(12))
              .foregroundStyle(Theme.secondary(scheme))
              .italic()
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(
                Theme.bubble(scheme, isSelf: true).opacity(0.65),
                in: RoundedRectangle(cornerRadius: 14))
              if !isSelf(LiveTranscriber.youSpeakerID) { Spacer(minLength: 48) }
            }
          }

          Color.clear.frame(height: 1).id("granola-live-bottom")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      }
      // Jump to the bottom once on appear so the latest turn is visible,
      // but don't force-scroll afterwards — the user can scroll up to
      // read earlier turns without being yanked back down on every update.
      .onAppear { proxy.scrollTo("granola-live-bottom", anchor: .bottom) }
      .onChange(of: searchQuery) {
        guard let first = filteredPriorTurns.first ?? filteredLiveTurns.first else { return }
        proxy.scrollTo(first.id, anchor: .top)
      }
    }
  }

  private func isSelf(_ speakerID: String) -> Bool {
    speakerID == LiveTranscriber.youSpeakerID
      || speakers.first(where: { $0.id == speakerID })?.isMe == true
  }

  private func name(for speakerID: String) -> String {
    if speakerID == LiveTranscriber.othersSpeakerID,
      let active = session.activeRemoteSpeaker
    {
      return active
    }
    return speakers.first(where: { $0.id == speakerID })?.name
      ?? LiveTranscriber.name(for: speakerID)
  }
}

struct TranscriptBubble: View {
  @Environment(\.colorScheme) private var scheme

  let turn: TranscriptTurn
  let isSelf: Bool
  let speakerName: String
  var searchQuery: String = ""

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      if isSelf { Spacer(minLength: 56) }

      VStack(alignment: isSelf ? .trailing : .leading, spacing: 3) {
        if !isSelf {
          Text(speakerName)
            .font(.nutola(10, .semibold))
            .foregroundStyle(Theme.tertiary(scheme))
        }
        TranscriptSearch.highlightedText(turn.text, query: searchQuery, scheme: scheme)
          .font(.nutola(12))
          .foregroundStyle(Theme.ink(scheme))
          .textSelection(.enabled)
          .lineSpacing(2)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            Theme.bubble(scheme, isSelf: isSelf),
            in: RoundedRectangle(cornerRadius: 14))
      }
      .frame(maxWidth: 340, alignment: isSelf ? .trailing : .leading)

      if !isSelf { Spacer(minLength: 56) }
    }
  }
}

/// Per-meeting transcription language picker shown in the live transcript header.
/// "Auto" = code-switching across reserved locales; selecting a specific locale
/// pins both channels to it for the rest of the call. Persists via the store so
/// the choice survives a resume.
struct LiveLocaleMenu: View {
  @ObservedObject var session: RecordingSession
  var store: TranscriptionLocaleStore
  @Environment(\.colorScheme) private var scheme

  private var current: String? {
    store.identifier(forMeetingID: session.meetingID.uuidString)
  }

  private var label: String {
    current.map { Self.shortLabel(for: $0) } ?? "Auto"
  }

  var body: some View {
    Menu {
      Button {
        session.setTranscriptionLocale(nil, store: store)
      } label: {
        if current == nil { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
      }
      Divider()
      ForEach(Self.entries(), id: \.0) { entry in
        Button {
          session.setTranscriptionLocale(entry.locale, store: store)
        } label: {
          if current == entry.id {
            Label(entry.label, systemImage: "checkmark")
          } else {
            Text(entry.label)
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "globe")
        Text(label)
      }
      .font(.nutola(11, .medium))
      .foregroundStyle(Theme.secondary(scheme))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Transcription language — pin to one locale or use Auto")
    .accessibilityLabel("Transcription language")
    .accessibilityValue(label)
  }

  private static func entries() -> [(id: String, label: String, locale: Locale)] {
    var seen = Set<String>()
    var out: [(id: String, label: String, locale: Locale)] = []
    for locale in [Locale.current] + TranscriptionLocales.presetLocales {
      let id = locale.identifier(.bcp47)
      guard seen.insert(id).inserted else { continue }
      let label = locale.localizedString(forIdentifier: id) ?? id
      out.append((id: id, label: label, locale: locale))
    }
    return out
  }

  private static func shortLabel(for identifier: String) -> String {
    Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
  }
}

enum TranscriptSearch {
  static func filter(_ turns: [TranscriptTurn], query: String) -> [TranscriptTurn] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return turns }
    return turns.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
  }

  static func highlightedText(_ text: String, query: String, scheme: ColorScheme) -> Text {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return Text(text) }

    var attributed = AttributedString(text)
    var searchStart = attributed.startIndex
    while searchStart < attributed.endIndex,
      let range = attributed[searchStart..<attributed.endIndex].range(
        of: trimmed,
        options: .caseInsensitive
      )
    {
      attributed[range].foregroundColor = Theme.mint(scheme)
      attributed[range].font = .body.weight(.semibold)
      searchStart = range.upperBound
    }
    return Text(attributed)
  }
}

// MARK: - Side notes (live scratch pad during recording)

struct SideNotesResizeHandle: View {
  @Environment(\.colorScheme) private var scheme
  @Binding var width: Double

  @State private var dragStartWidth: Double?
  @State private var isHovering = false

  private let minWidth = 200.0
  private let maxWidth = 520.0

  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06))
      .frame(width: 1)
      .frame(maxHeight: .infinity)
      .overlay {
        Rectangle()
          .fill(isHovering ? Theme.mint(scheme).opacity(0.35) : Color.clear)
          .frame(width: 6)
          .contentShape(Rectangle())
          .onHover { hovering in
            isHovering = hovering
            if hovering {
              NSCursor.resizeLeftRight.push()
            } else {
              NSCursor.pop()
            }
          }
          .gesture(
            DragGesture(minimumDistance: 1)
              .onChanged { value in
                if dragStartWidth == nil { dragStartWidth = width }
                let proposed = (dragStartWidth ?? width) + value.translation.width
                width = min(max(proposed, minWidth), maxWidth)
              }
              .onEnded { _ in dragStartWidth = nil }
          )
      }
  }
}

struct SideNotesPanel: View {
  @Environment(\.colorScheme) private var scheme
  @Binding var text: String
  let isRecording: Bool
  var onTextChange: () -> Void

  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().opacity(0.25)

      ZStack(alignment: .topLeading) {
        TextEditor(text: $text)
          .font(.nutola(14))
          .foregroundStyle(Theme.heading(scheme))
          .scrollContentBackground(.hidden)
          .focused($focused)
          .onChange(of: text) { onTextChange() }

        if text.isEmpty {
          Text("Write notes")
            .font(.nutola(14))
            .foregroundStyle(Theme.tertiary(scheme))
            .padding(.leading, 5)
            .allowsHitTesting(false)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxHeight: .infinity)
    }
    .background(Theme.panel(scheme))
    .onAppear {
      if isRecording { focused = true }
    }
    .onChange(of: isRecording) { _, recording in
      if recording { focused = true }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if isRecording {
        RecordDot()
          .accessibilityLabel("Nutola is listening")
      }
      Text("My notes")
        .font(.nutola(13, .semibold))
        .foregroundStyle(Theme.heading(scheme))
      Spacer()
      if isRecording {
        Text("Live")
          .font(.nutola(10, .semibold))
          .foregroundStyle(Theme.mint(scheme))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Theme.mint(scheme).opacity(0.12), in: Capsule())
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}
