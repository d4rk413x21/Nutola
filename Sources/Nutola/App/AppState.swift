import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import os

extension Notification.Name {
  /// Posted after bootstrap warms Claude/Codex auth caches off the main thread.
  static let nutolaCLIAvailabilityChanged = Notification.Name("NutolaCLIAvailabilityChanged")
}

@MainActor
final class AppState: NSObject, ObservableObject {
  static let shared: AppState = {
    MainActor.assumeIsolated {
      AppState(container: DependencyContainer.live())
    }
  }()

  private let container: DependencyContainer

  var store: MeetingStore { container.meetingStore }
  var templates: TemplateStore { container.templateStore }
  var templateOverrides: TemplateOverrideStore { container.templateOverrideStore }
  var localeOverrides: TranscriptionLocaleStore { container.localeOverrideStore }
  var calendar: CalendarStore { container.calendarStore }
  var folders: MeetingFolderStore { container.folderStore }
  var tracker: TaskTrackerStore { container.taskTracker }

  @Published private(set) var session: RecordingSession?
  @Published private(set) var recordingMeeting: Meeting?
  /// Signal-safe mirror of the in-flight meeting metadata, kept in sync with
  /// `recordingMeeting` so `CrashDiagnosticLog` can read it from a signal handler
  /// without touching the @MainActor. Only id/title/state/notice — never audio.
  nonisolated(unsafe) private var inFlightCrashMirror: CrashDiagnosticLog.InFlightMeeting?
  @Published var recordingCardDismissed = false
  @Published var recordingCardMinimized = true
  @Published var showLiveRecordingCard: Bool
  @Published private(set) var processingStage: [UUID: String] = [:]
  @Published private(set) var streamingSummaries: [UUID: String] = [:]
  @Published private(set) var summaryProgress: [UUID: SummaryProgress] = [:]
  @Published private(set) var detectedAppName: String?
  /// Last user-facing error message. Stored as `localizedDescription` (a String)
  /// rather than the typed `Error` so SwiftUI can bind it directly; the original
  /// error type is intentionally dropped — the message is for display, not retry
  /// logic. Set to nil to clear the banner.
  @Published var lastError: String?
  @Published var openMeetingID: UUID?
  @Published private(set) var activeMicApps: [pid_t: String] = [:]
  @Published private(set) var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
  var activeMicAppNames: [String] { Array(Set(activeMicApps.values)).sorted() }

  private var cancellables = Set<AnyCancellable>()

  func meetingForCalendarEvent(_ event: CalendarEventSummary) -> Meeting? {
    container.calendarRepository.meetingForCalendarEvent(event, in: store.meetings)
  }

  var isRecording: Bool { session != nil || container.recordingService.isRecording }

  /// A meeting left in a resumable state (failed/ready/prep) when no session is
  /// active — e.g. a crash-orphaned recording the user is about to rejoin. The
  /// menu bar uses this to swap "Start recording" for "Resume recording".
  /// Only returns meetings whose calendar event is still in progress — if the
  /// event has ended, the user should see "Start recording" instead.
  var resumableMeeting: Meeting? {
    guard session == nil, !container.recordingService.isRecording else { return nil }
    return store.meetings.first { meeting in
      meeting.canResumeRecording(isRecording: false) && meetingIsStillLive(meeting)
    }
  }

  /// True only if the meeting's calendar event is currently in progress.
  /// Meetings without a calendar link are never auto-resumable from the
  /// menu bar — the user should see "Start recording" instead.
  private func meetingIsStillLive(_ meeting: Meeting) -> Bool {
    guard let eventID = meeting.calendarEventID,
      let event = calendar.event(id: eventID, start: meeting.calendarEventStart)
    else { return false }
    return event.isInProgress
  }

  /// Resume the most recent resumable meeting, if any. Used by the menu bar's
  /// "Resume recording" button when no session is live.
  func resumeOrphanIfAny() async {
    guard let meeting = resumableMeeting else { return }
    await continueRecording(meetingID: meeting.id)
  }

  private init(container: DependencyContainer) {
    self.container = container
    showLiveRecordingCard = container.settings.showLiveRecordingCard
    super.init()
    wireUseCaseCallbacks()
    wireDetectionCoordinator()
    wireStoreForwarding()
  }

  private func wireStoreForwarding() {
    AppSettings.registerDefaults()
    showLiveRecordingCard = container.settings.showLiveRecordingCard
    store.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    calendar.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    folders.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    templateOverrides.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    tracker.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    store.onSummarySaved = { [weak self] meetingID, markdown in
      guard let self, let meeting = self.store.meeting(id: meetingID) else { return }
      self.tracker.syncFromMeeting(meeting, summary: markdown)
    }
    store.onMeetingDeleted = { [weak self] meetingID in
      self?.tracker.removeTasks(forMeetingID: meetingID)
    }
  }

  private func wireUseCaseCallbacks() {
    container.processMeeting.onProgress = { [weak self] id, stage in
      if let stage { self?.processingStage[id] = stage } else { self?.processingStage[id] = nil }
    }
    container.processMeeting.onSummaryProgress = { [weak self] id, progress in
      self?.summaryProgress[id] = progress
    }
    container.processMeeting.onSummaryUpdate = { [weak self] id, update in
      self?.applySummaryUpdate(update, for: id)
    }
    container.regenerateSummary.onProgress = { [weak self] id, stage in
      if let stage { self?.processingStage[id] = stage } else { self?.processingStage[id] = nil }
    }
    container.regenerateSummary.onStreamingSummary = { [weak self] id, text in
      if let text {
        self?.streamingSummaries[id] = text
      } else {
        self?.streamingSummaries[id] = nil
      }
    }
    container.regenerateSummary.onSummaryProgress = { [weak self] id, progress in
      self?.summaryProgress[id] = progress
    }
  }

  private func wireDetectionCoordinator() {
    let coordinator = container.detectionCoordinator
    coordinator.isRecording = { [weak self] in self?.isRecording ?? false }
    coordinator.isStartingRecording = { [weak self] in
      self?.container.recordingService.isStartingRecording ?? false
    }
    coordinator.onDetectedAppNameChanged = { [weak self] name in
      self?.detectedAppName = name
    }
    coordinator.onActiveMicAppsChanged = { [weak self] apps in
      self?.activeMicApps = apps
    }
    coordinator.onDetectionChime = { [weak self] in
      self?.container.notificationService.playDetectionChime()
    }
    coordinator.onAutoRecord = { [weak self] name in
      await self?.startRecording(sourceApp: name)
    }
    coordinator.onAutoStop = { [weak self] in
      await self?.stopRecording()
    }
  }

  /// Heals a stale UI when capture is live in `RecordingService` but `session` was never set.
  func reconcileRecordingState() {
    guard session == nil,
      let svcSession = container.recordingService.currentSession,
      let meeting = container.recordingService.recordingMeeting
    else { return }
    applyRecordingHandle(RecordingSessionHandle(session: svcSession, meeting: meeting))
    lastError = nil
  }

  func bootstrap() {
    NutolaConsoleLog.app("bootstrap starting")
    // Hand the crash logger a signal-safe reader for the in-flight meeting.
    CrashDiagnosticLog.inFlightMeetingSnapshot = { [weak self] in
      // Plain struct read — safe from a signal handler. The mirror is
      // updated on the main thread whenever recording starts/stops.
      return self?.inFlightCrashMirror
    }
    container.notificationService.configure { [weak self] id in
      Task { @MainActor in
        self?.openMeetingID = id
      }
    }
    finalizeOrphans()
    Task.detached {
      _ = ClaudeCLI.resolveBlocking()
      _ = CodexCLI.resolveBlocking()
      _ = AgentCLI.resolveBlocking(.opencode)
      _ = AgentCLI.resolveBlocking(.vibe)
      ClaudeCLI.warmAuthCache()
      CodexCLI.warmAuthCache()
      await MainActor.run {
        NutolaConsoleLog.app("CLI availability refreshed")
        NotificationCenter.default.post(name: .nutolaCLIAvailabilityChanged, object: nil)
      }
    }
    Task { @MainActor in
      await Task.detached { SystemAudioTap.destroyLeftoverAggregates() }.value
      if container.settings.detectMeetings {
        NutolaConsoleLog.app("starting meeting detection")
        startDetection()
      }
      await calendar.refreshAgenda()
      notificationAuthStatus = await container.notificationService.refreshAuthorizationStatus()
      NutolaConsoleLog.app(
        "bootstrap done — meetings=\(store.meetings.count) calendarAuth=\(CalendarAuthorization.isAuthorized)"
          + " detect=\(container.settings.detectMeetings)")
    }
  }

  private func updateInFlightCrashMirror() {
    guard let meeting = recordingMeeting else {
      inFlightCrashMirror = nil
      return
    }
    inFlightCrashMirror = CrashDiagnosticLog.InFlightMeeting(
      id: meeting.id.uuidString,
      title: meeting.title,
      state: meeting.state.rawValue,
      notice: meeting.notice)
  }

  func prepareForTermination() async {
    await container.recordingService.prepareForTermination(meetingRepository: store)
    session = nil
    recordingMeeting = nil
    updateInFlightCrashMirror()
  }

  // MARK: - Detection

  func startDetection() {
    NutolaConsoleLog.detection("AppState.startDetection")
    container.detectionCoordinator.start()
  }

  func stopDetection() {
    NutolaConsoleLog.detection("AppState.stopDetection")
    container.detectionCoordinator.stop()
  }

  func acceptDetection() async {
    lastError = nil
    resetRecordingCardState()
    let appName = detectedAppName
    container.detectionCoordinator.dismissDetection()
    switch await container.startRecording.execute(
      sourceApp: appName,
      calendarEvent: nil)
    {
    case .success(let handle):
      applyRecordingHandle(handle)
    case .failure(let error):
      lastError = error.localizedDescription
    }
  }

  func dismissDetection() {
    container.detectionCoordinator.dismissDetection()
  }

  // MARK: - Recording

  func startRecording(
    sourceApp: String? = nil,
    trigger: MicEvent? = nil,
    calendarEvent: CalendarEventSummary? = nil
  ) async {
    lastError = nil
    resetRecordingCardState()
    let resolvedSource = sourceApp ?? inferredMeetingSource()
    container.detectionCoordinator.dismissDetection()
    switch await container.startRecording.execute(
      sourceApp: resolvedSource,
      calendarEvent: calendarEvent)
    {
    case .success(let handle):
      applyRecordingHandle(handle)
    case .failure(let error):
      if error == .alreadyRecording {
        reconcileRecordingState()
        if session != nil { return }
      }
      lastError = error.localizedDescription
      NutolaConsoleLog.recording("start failed — \(error.localizedDescription)")
    }
  }

  /// Manual starts still tag Zoom/Teams when that app is on the mic.
  private func inferredMeetingSource() -> String? {
    guard !activeMicAppNames.isEmpty else { return nil }
    let inferred = MeetingDetector.inferSourceApp(from: activeMicAppNames)
    if let inferred {
      NutolaConsoleLog.recording(
        "inferred source=\(inferred) from active mic [\(activeMicAppNames.joined(separator: ", "))]"
      )
    }
    return inferred
  }

  func stopRecording() async {
    NutolaConsoleLog.recording("AppState.stopRecording")
    session = nil
    recordingMeeting = nil
    updateInFlightCrashMirror()
    _ = await container.stopRecording.execute()
  }

  func discardRecording() {
    NutolaConsoleLog.recording("AppState.discardRecording")
    session = nil
    recordingMeeting = nil
    updateInFlightCrashMirror()
    container.discardRecording.execute()
  }

  func openCalendarEvent(_ event: CalendarEventSummary) {
    Task {
      switch await container.openCalendarEvent.execute(event) {
      case .openExisting(let id), .prepared(let id):
        openMeetingID = id
      case .failed:
        lastError = "Could not prepare meeting."
      }
    }
  }

  func prepareMeeting(calendarEvent: CalendarEventSummary) async {
    switch container.prepareMeeting.execute(calendarEvent: calendarEvent) {
    case .success(let meeting):
      openMeetingID = meeting.id
    case .failure(let error):
      lastError = error.localizedDescription
    }
  }

  func continueRecording(meetingID: UUID) async {
    lastError = nil
    resetRecordingCardState()
    container.detectionCoordinator.dismissDetection()
    // If this meeting is mid-finalization (orphan resumed on the same launch
    // that's finalizing it), cancel the process task so its audio/transcript
    // files can be safely reset for the resumed recording.
    cancelOrphanProcessing(meetingID)
    switch await container.continueRecording.execute(meetingID: meetingID) {
    case .success(let handle):
      applyRecordingHandle(handle)
      openMeetingID = handle.meeting.id
    case .failure(let error):
      lastError = error.localizedDescription
    }
  }

  private func applyRecordingHandle(_ handle: RecordingSessionHandle) {
    session = handle.session
    recordingMeeting = handle.meeting
    updateInFlightCrashMirror()
    openMeetingID = handle.meeting.id
  }

  private func resetRecordingCardState() {
    recordingCardDismissed = false
    recordingCardMinimized = true
  }

  // MARK: - Processing

  func process(_ meeting: Meeting) async {
    await container.processMeeting.execute(meeting)
    streamingSummaries[meeting.id] = nil
  }

  func retry(meetingID: UUID) async {
    await container.retryMeeting.execute(meetingID: meetingID)
  }

  func importAudio(fileURL: URL, title: String? = nil) async -> UUID? {
    lastError = nil
    do {
      let id = try await container.importAudio.execute(fileURL: fileURL, title: title)
      openMeetingID = id
      return id
    } catch {
      lastError = error.localizedDescription
      NutolaConsoleLog.processing("import audio failed — \(error.localizedDescription)")
      return nil
    }
  }

  func regenerateSummary(
    meetingID: UUID, templateName: String? = nil, forceProvider: AIProvider? = nil
  ) async {
    await container.regenerateSummary.execute(
      meetingID: meetingID, templateName: templateName, forceProvider: forceProvider)
  }

  private func applySummaryUpdate(_ update: ProcessingPipeline.SummaryUpdate, for id: UUID) {
    switch update {
    case .streaming(let text):
      summaryProgress[id] = .streaming
      streamingSummaries[id] = text
    case .draftSaved:
      summaryProgress[id] = .improving
      streamingSummaries[id] = nil
    case .done:
      summaryProgress[id] = nil
      streamingSummaries[id] = nil
    }
  }

  /// In-flight orphan-finalization tasks, keyed by meeting ID. When a detection-
  /// driven startRecording races finalizeOrphans on the same launch and resumes
  /// the orphan, we cancel its process task so the audio/transcript files can be
  /// safely reset for the resumed recording without a write/read collision.
  private var orphanProcessTasks: [UUID: Task<Void, Never>] = [:]

  /// Max number of orphans finalized at once. Each `process(_:)` run drives
  /// transcription + a model call; running several in parallel could starve
  /// the CPU/GPU and starve the foreground recording. 2 keeps recovery quick
  /// without overwhelming the machine. (Was unbounded — a `Task` per orphan.)
  private static let orphanFinalizeConcurrency = 2

  private func finalizeOrphans() {
    let orphans = store.meetings.filter { $0.state == .recording || $0.state == .processing }
    if orphans.isEmpty { return }
    NutolaConsoleLog.processing("finalizing \(orphans.count) orphan meeting(s)")
    // Flip each to .processing SYNCHRONOUSLY, before any async work, so a
    // detection-driven startRecording that races on the same launch can't see
    // an orphan still in .recording and create a duplicate meeting for the same
    // calendar event. .processing is not a live session — no RecordingSession
    // holds it — so the resume matcher (which treats .processing as resumable
    // when no session is live) can rejoin it.
    var prepared: [Meeting] = []
    for meeting in orphans {
      var m = meeting
      m.state = .processing
      if m.duration == 0 {
        m.duration = audioDuration(archive: store.archive, id: m.id)
      }
      store.upsert(m)
      prepared.append(m)
    }
    // Run the (minutes-long) pipeline with bounded concurrency instead of
    // launching a Task per orphan. Start at most
    // `orphanFinalizeConcurrency` orphans per wave, awaiting the
    // wave, then refilling. Each orphan keeps its own Task in
    // `orphanProcessTasks` so `cancelOrphanProcessing` can still cancel it
    // individually (e.g. when the user resumes that meeting).
    Task { @MainActor in
      var index = 0
      while index < prepared.count {
        let wave = prepared[index..<min(index + Self.orphanFinalizeConcurrency, prepared.count)]
        index += wave.count
        let tasks = wave.map { meeting in
          let task = Task { await process(meeting) }
          orphanProcessTasks[meeting.id] = task
          return (meeting.id, task)
        }
        for (id, task) in tasks {
          await task.value
          orphanProcessTasks[id] = nil
        }
      }
    }
  }

  /// Cancel the orphan-finalization task for a meeting (e.g. when resuming it).
  func cancelOrphanProcessing(_ meetingID: UUID) {
    orphanProcessTasks[meetingID]?.cancel()
    orphanProcessTasks[meetingID] = nil
  }

  private nonisolated func audioDuration(archive: MeetingArchive, id: UUID) -> TimeInterval {
    for url in [archive.micURL(for: id), archive.systemURL(for: id)] {
      if let seconds = try? AVAudioFileLength(url), seconds > 0 { return seconds }
    }
    return 0
  }

  // MARK: - Notifications

  func refreshNotificationStatus() async {
    notificationAuthStatus = await container.notificationService.refreshAuthorizationStatus()
  }

  func requestNotificationAuthorization() async {
    await container.notificationService.requestAuthorization()
    await refreshNotificationStatus()
  }
}

private func AVAudioFileLength(_ url: URL) throws -> TimeInterval {
  let file = try AVAudioFile(forReading: url)
  return Double(file.length) / file.processingFormat.sampleRate
}
