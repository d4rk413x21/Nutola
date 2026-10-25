import AVFoundation
import AppKit
import Foundation
import UserNotifications
import os

@MainActor
final class RecordingServiceImpl: RecordingService {
  private(set) var currentSession: RecordingSession?
  private(set) var recordingMeeting: Meeting?
  private var _isStartingRecording = false
  private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "recording")
  /// Per-meeting transcription locale overrides. Injected by the dependency
  /// container; nil in tests means "auto" for every meeting.
  var localeStore: TranscriptionLocaleStore?

  var isRecording: Bool { currentSession != nil }
  var isStartingRecording: Bool { _isStartingRecording }

  func startRecording(
    sourceApp: String?,
    calendarEvent: CalendarEventSummary?,
    meetingRepository: MeetingRepository,
    folderRepository: FolderRepository,
    calendarRepository: CalendarRepository,
    settings: SettingsRepository,
    templateOverrides: TemplateOverrideRepository?,
    availableTemplateNames: @escaping () -> [String]
  ) async -> Result<RecordingSessionHandle, RecordingError> {
    guard !isRecording, !isStartingRecording else { return .failure(.alreadyRecording) }
    NutolaConsoleLog.recording(
      "start requested source=\(sourceApp ?? "manual") calendar=\(calendarEvent?.title ?? "none")")

    if !MicRecorder.permissionGranted {
      let granted = await MicRecorder.requestPermission()
      NutolaConsoleLog.recording(
        "mic permission requested granted=\(granted) status=\(MicRecorder.permissionGranted)")
      if !granted {
        // The TCC prompt was denied or didn't appear (common with ad-hoc
        // signed apps after a rebuild — macOS silently denies). Open
        // System Settings so the user can toggle it manually.
        NutolaConsoleLog.recording("mic permission DENIED — opening System Settings → Microphone")
        await MainActor.run {
          if let url = URL(
            string:
              "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
          ) {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
    let sysBefore = SystemAudioPermission.statusLabel
    if SystemAudioPermission.status() == .unknown {
      await SystemAudioPermission.request()
    }
    NutolaConsoleLog.recording(
      "permissions mic=\(MicRecorder.permissionGranted) system=\(SystemAudioPermission.statusLabel) (was \(sysBefore))"
    )

    let resolvedCalendarEvent = await resolveCalendarEvent(
      calendarEvent: calendarEvent,
      sourceApp: sourceApp,
      calendarRepository: calendarRepository,
      meetingRepository: meetingRepository,
      settings: settings)

    // Resume an existing meeting for this calendar event (e.g. re-joining a call
    // after a crash). Delegate to continueRecording WITHOUT holding the
    // _isStartingRecording flag — continueRecording manages its own, and its
    // `!isStartingRecording` guard would otherwise reject us with
    // .alreadyRecording, leaving the orphan un-resumable through this path.
    if let event = resolvedCalendarEvent,
      let existing = calendarRepository.meetingForCalendarEvent(
        event, in: meetingRepository.meetings),
      existing.canResumeRecording(isRecording: false)
    {
      NutolaConsoleLog.recording("resuming existing meeting for calendar event \"\(event.title)\"")
      // A crash-orphan may have been created before the source was known
      // (sourceApp == nil), which stops the Zoom speaker tracker from
      // starting on resume — so the live UI gets no named speakers and
      // the final transcript has no roster. Update it to the source we
      // just detected (e.g. Zoom) so the tracker starts on the resumed call.
      if let sourceApp, existing.sourceApp == nil {
        var updated = existing
        updated.sourceApp = sourceApp
        meetingRepository.upsert(updated)
        NutolaConsoleLog.recording(
          "resume: set source=\(sourceApp) on orphan \(existing.id.uuidString.prefix(8))")
      }
      return await continueRecording(meetingID: existing.id, meetingRepository: meetingRepository)
    }

    // Fresh start: claim the flag only now, after the resume branch. The
    // resume path above owns its own flag lifecycle.
    _isStartingRecording = true
    defer { _isStartingRecording = false }

    var meeting = Meeting(title: Meeting.placeholderTitle(for: Date()), createdAt: Date())
    meeting.sourceApp = sourceApp
    meeting.templateName = settings.defaultTemplate

    if let resolvedCalendarEvent {
      applyCalendarEvent(resolvedCalendarEvent, to: &meeting)
      NutolaConsoleLog.recording(
        "matched calendar \"\(resolvedCalendarEvent.title)\" (\(resolvedCalendarEvent.attendees.count) attendees)"
      )
    }

    // Smart templates: once the calendar event (title + attendees) is applied,
    // override the default template with the one the resolver picks for this
    // meeting type. Transcript keywords aren't available yet at start time.
    if settings.smartTemplatesEnabled {
      let type = MeetingTemplateResolver.resolve(for: meeting)
      meeting.templateName = MeetingTemplateResolver.templateName(for: type)
      NutolaConsoleLog.intelligence(
        "smart template → \(type.rawValue) (\"\(meeting.templateName ?? "")\")")
    }
    // Per-event assignment wins over both default and smart — same precedence
    // as PrepareMeetingUseCase, so manual and auto-detected starts agree.
    if let event = resolvedCalendarEvent,
      let override = templateOverrides?.templateName(
        forEventID: event.id, available: availableTemplateNames())
    {
      meeting.templateName = override
      NutolaConsoleLog.intelligence("per-event template → \"\(override)\" for \"\(event.title)\"")
    }

    if let title = meeting.calendarEventTitle,
      let folder = folderRepository.folder(forTitle: title)
    {
      meeting.folderID = folder.id
      NutolaConsoleLog.recording("auto-folder \"\(folder.name)\"")
    }

    guard !isRecording else { return .failure(.alreadyRecording) }

    return await startSession(for: meeting, meetingRepository: meetingRepository)
  }

  func continueRecording(
    meetingID: UUID,
    meetingRepository: MeetingRepository
  ) async -> Result<RecordingSessionHandle, RecordingError> {
    guard !isRecording, !isStartingRecording else { return .failure(.alreadyRecording) }
    guard var meeting = meetingRepository.meeting(id: meetingID) else {
      NutolaConsoleLog.recording("continue failed — meeting not found")
      return .failure(.meetingNotFound)
    }
    let fromPrep = meeting.canStartFromPrep(isRecording: false)
    guard fromPrep || meeting.canContinueRecording(isRecording: false) else {
      NutolaConsoleLog.recording(
        "continue failed — meeting \(meetingID.uuidString.prefix(8)) not resumable")
      return .failure(.cannotContinue)
    }
    NutolaConsoleLog.recording(
      "continue \(meetingID.uuidString.prefix(8)) fromPrep=\(fromPrep) duration=\(Int(meeting.duration))s"
    )

    // Claim the meeting and reset its files SYNCHRONOUSLY, before the async
    // permission awaits below. A late orphan-finalization task (cancel is
    // cooperative, so process() may still be mid-flight) reads the meeting
    // fresh and bails on `guard fresh.state == .processing` once we've flipped
    // to .recording — so flip first. This also reclaims the audio/transcript
    // files before process() can write them.
    let archive = meetingRepository.archive
    if !fromPrep {
      for url in [archive.micURL(for: meetingID), archive.systemURL(for: meetingID)] {
        try? FileManager.default.removeItem(at: url)
      }
      archive.removeLiveTranscript(for: meetingID)
      archive.removePlatformSpeakerEvents(for: meetingID)
      archive.removeZoomRoster(for: meetingID)
    }
    meeting.state = .recording
    meeting.notice = nil
    meetingRepository.upsert(meeting)

    _isStartingRecording = true
    defer { _isStartingRecording = false }

    if !MicRecorder.permissionGranted {
      let granted = await MicRecorder.requestPermission()
      NutolaConsoleLog.recording(
        "mic permission requested granted=\(granted) status=\(MicRecorder.permissionGranted)")
      if !granted {
        NutolaConsoleLog.recording("mic permission DENIED — opening System Settings → Microphone")
        await MainActor.run {
          if let url = URL(
            string:
              "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
          ) {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
    let sysBefore = SystemAudioPermission.statusLabel
    if SystemAudioPermission.status() == .unknown {
      await SystemAudioPermission.request()
    }
    NutolaConsoleLog.recording(
      "permissions mic=\(MicRecorder.permissionGranted) system=\(SystemAudioPermission.statusLabel) (was \(sysBefore))"
    )
    guard !isRecording else { return .failure(.alreadyRecording) }

    let newSession = RecordingSession(
      meetingID: meeting.id,
      archive: archive,
      elapsedOffset: meeting.duration,
      sourceApp: meeting.sourceApp)
    do {
      try await newSession.startAsync(
        micURL: archive.micURL(for: meeting.id),
        systemURL: archive.systemURL(for: meeting.id),
        localeStore: localeStore)
    } catch {
      meeting.state = .failed
      meeting.notice = error.localizedDescription
      meetingRepository.upsert(meeting)
      NutolaConsoleLog.recording("continue session start failed — \(error.localizedDescription)")
      return .failure(.sessionStartFailed(error.localizedDescription))
    }
    meeting.notice = newSession.startupNotice
    meetingRepository.upsert(meeting)
    currentSession = newSession
    recordingMeeting = meeting
    NutolaConsoleLog.recording(
      "continue started \(meetingID.uuidString.prefix(8)) notice=\(newSession.startupNotice ?? "none")"
    )
    return .success(RecordingSessionHandle(session: newSession, meeting: meeting))
  }

  func stop() async -> (session: RecordingSession, meeting: Meeting)? {
    guard let session = currentSession, let meeting = recordingMeeting else { return nil }
    NutolaConsoleLog.recording(
      "stop \(meeting.id.uuidString.prefix(8)) elapsed=\(Int(session.elapsed))s")
    // Claim the session immediately so another stop cannot finalize it twice.
    clear()
    // AAC metadata/headers are only reliable after AVAudioFile is closed.
    // Unlike stop(), stopAsync() waits for both recorders and live.json.
    await session.stopAsync()
    NutolaConsoleLog.recording(
      "capture finalized before processing \(meeting.id.uuidString.prefix(8))")
    return (session, meeting)
  }

  func discard() -> (session: RecordingSession, meeting: Meeting)? {
    guard let session = currentSession, let meeting = recordingMeeting else { return nil }
    NutolaConsoleLog.recording("discard \(meeting.id.uuidString.prefix(8))")
    clear()
    session.stop()
    return (session, meeting)
  }

  func prepareForTermination(meetingRepository: MeetingRepository) {
    guard let session = currentSession, let meeting = recordingMeeting else { return }
    NutolaConsoleLog.recording("app terminating — finalizing \(meeting.id.uuidString.prefix(8))")
    session.stop()
    if var fresh = meetingRepository.meeting(id: meeting.id) ?? recordingMeeting {
      fresh.duration = session.elapsed
      fresh.state = .processing
      meetingRepository.upsert(fresh)
    }
    clear()
  }

  private func startSession(
    for meeting: Meeting,
    meetingRepository: MeetingRepository
  ) async -> Result<RecordingSessionHandle, RecordingError> {
    let archive = meetingRepository.archive
    do {
      try archive.createFolder(for: meeting.id)
    } catch {
      NutolaConsoleLog.recording("archive folder creation failed — \(error.localizedDescription)")
      return .failure(.archiveCreationFailed(error.localizedDescription))
    }

    let newSession = RecordingSession(
      meetingID: meeting.id,
      archive: archive,
      sourceApp: meeting.sourceApp)
    do {
      try await newSession.startAsync(
        micURL: archive.micURL(for: meeting.id),
        systemURL: archive.systemURL(for: meeting.id),
        localeStore: localeStore)
    } catch {
      try? FileManager.default.removeItem(at: archive.folder(for: meeting.id))
      NutolaConsoleLog.recording("session start failed — \(error.localizedDescription)")
      return .failure(.sessionStartFailed(error.localizedDescription))
    }
    var saved = meeting
    saved.state = .recording
    saved.notice = newSession.startupNotice
    meetingRepository.upsert(saved)
    currentSession = newSession
    recordingMeeting = saved
    NutolaConsoleLog.recording(
      "started \(meeting.id.uuidString.prefix(8)) title=\"\(meeting.title)\" notice=\(newSession.startupNotice ?? "none")"
    )
    return .success(RecordingSessionHandle(session: newSession, meeting: saved))
  }

  private func clear() {
    currentSession = nil
    recordingMeeting = nil
  }

  private func resolveCalendarEvent(
    calendarEvent: CalendarEventSummary?,
    sourceApp: String?,
    calendarRepository: CalendarRepository,
    meetingRepository: MeetingRepository,
    settings: SettingsRepository
  ) async -> CalendarEventSummary? {
    if let calendarEvent { return calendarEvent }
    guard settings.useCalendar, CalendarAuthorization.isAuthorized else { return nil }
    if let current = await calendarRepository.currentEvent(at: .now, sourceApp: sourceApp) {
      return current
    }
    // Fallback: detection fired slightly before the calendar event's start
    // (the user joined the call early, or the event starts in a few minutes).
    // `currentEvent` only looks 10 min forward; a prep meeting created from
    // the Coming Up view still has the event's real start, so reuse it and
    // avoid creating a duplicate recording entry with no calendar link.
    let now = Date()
    let archive = ArchivedEventStore()
    let candidates = meetingRepository.meetings.filter { meeting in
      guard meeting.state == .prep,
            meeting.calendarEventID != nil,
            let start = meeting.calendarEventStart
      else { return false }
      // Skip prep meetings whose calendar event was archived after they were
      // prepared — archived events must never become recordings.
      if let eid = meeting.calendarEventID,
         archive.isArchived(title: meeting.calendarEventTitle ?? meeting.title, eventID: eid) {
        return false
      }
      return abs(start.timeIntervalSince(now)) <= 15 * 60
    }
    if let prep = candidates.first,
       let id = prep.calendarEventID,
       let start = prep.calendarEventStart,
       let end = prep.calendarEventEnd {
      return CalendarEventSummary(
        id: id,
        title: prep.calendarEventTitle ?? prep.title,
        start: start,
        end: end,
        location: nil,
        attendees: prep.attendees,
        conferenceURL: nil,
        calendarID: nil,
        calendarTitle: nil,
        calendarColor: .gray)
    }
    return nil
  }

  private func applyCalendarEvent(_ event: CalendarEventSummary, to meeting: inout Meeting) {
    meeting.title = event.title
    meeting.calendarEventTitle = event.title
    meeting.attendees = event.attendees
    meeting.calendarEventID = event.id
    meeting.calendarEventStart = event.start
    meeting.calendarEventEnd = event.end
  }
}

final class NotificationServiceImpl: NotificationService, @unchecked Sendable {
  private var onReadyTapped: (@Sendable (UUID) -> Void)?
  private var detectionChime: NSSound?
  private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "notifications")

  func configure(onReadyTapped: @escaping @Sendable (UUID) -> Void) {
    self.onReadyTapped = onReadyTapped
    guard Bundle.main.bundleIdentifier != nil else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = NotificationCenterDelegate.shared
    NotificationCenterDelegate.shared.onReadyTapped = onReadyTapped
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      self.log.info(
        "notification auth granted=\(granted) error=\(error?.localizedDescription ?? "none", privacy: .public)"
      )
      NutolaConsoleLog.notification(
        "auth granted=\(granted) error=\(error?.localizedDescription ?? "none")")
    }
  }

  func requestAuthorization() async {
    let center = UNUserNotificationCenter.current()
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  func notifyMeetingReady(_ meeting: Meeting) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    NutolaConsoleLog.notification(
      "meeting ready \"\(meeting.title)\" (\(meeting.id.uuidString.prefix(8)))")
    let content = UNMutableNotificationContent()
    content.title = meeting.title
    content.body = "Your meeting notes are ready."
    let request = UNNotificationRequest(
      identifier: "ready-\(meeting.id)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  func playDetectionChime() {
    guard Bundle.main.bundleIdentifier != nil else { return }
    if detectionChime?.isPlaying == true { return }
    NutolaConsoleLog.notification("detection chime")
    let sound = NSSound(named: NSSound.Name("Ping"))
    detectionChime = sound
    sound?.play()
  }
}

/// Bridges UNUserNotificationCenterDelegate to the Sendable notification service.
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  static let shared = NotificationCenterDelegate()
  var onReadyTapped: (@Sendable (UUID) -> Void)?

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let identifier = response.notification.request.identifier
    guard identifier.hasPrefix("ready-"),
      let id = UUID(uuidString: String(identifier.dropFirst("ready-".count)))
    else { return }
    await MainActor.run {
      onReadyTapped?(id)
      NSApp.activate()
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
