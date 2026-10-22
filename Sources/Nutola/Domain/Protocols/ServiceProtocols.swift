import Foundation

// MARK: - Recording

struct RecordingSessionHandle {
    let session: RecordingSession
    let meeting: Meeting
}

/// Captures mic + system audio for a meeting (SRP: recording lifecycle only).
@MainActor
protocol RecordingService: AnyObject {
    var isRecording: Bool { get }
    var isStartingRecording: Bool { get }
    var currentSession: RecordingSession? { get }
    var recordingMeeting: Meeting? { get }

    func startRecording(
        sourceApp: String?,
        calendarEvent: CalendarEventSummary?,
        meetingRepository: MeetingRepository,
        folderRepository: FolderRepository,
        calendarRepository: CalendarRepository,
        settings: SettingsRepository,
        templateOverrides: TemplateOverrideRepository?,
        availableTemplateNames: @escaping () -> [String]
    ) async -> Result<RecordingSessionHandle, RecordingError>

    func continueRecording(
        meetingID: UUID,
        meetingRepository: MeetingRepository
    ) async -> Result<RecordingSessionHandle, RecordingError>

    /// Returns only after capture files and the live transcript have been finalized.
    /// Processing must never start while .m4a files are still being written.
    func stop() async -> (session: RecordingSession, meeting: Meeting)?
    func discard() -> (session: RecordingSession, meeting: Meeting)?
    func prepareForTermination(meetingRepository: MeetingRepository)
}

enum RecordingError: LocalizedError, Equatable {
    case alreadyRecording
    case archiveCreationFailed(String)
    case sessionStartFailed(String)
    case meetingNotFound
    case cannotContinue

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress."
        case .archiveCreationFailed(let why): why
        case .sessionStartFailed(let why): why
        case .meetingNotFound: "Meeting not found."
        case .cannotContinue: "This meeting cannot be continued."
        }
    }
}

// MARK: - Processing

enum SummaryProgress: Sendable, Equatable {
    case streaming
    case improving
}

/// Post-recording transcription, diarization, and summarization (SRP).
protocol ProcessingService: Sendable {
    func process(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void,
        onSummary: @escaping @Sendable (ProcessingPipeline.SummaryUpdate) -> Void
    ) async -> ProcessingPipeline.Outcome

    func summarize(
        meeting: Meeting,
        transcript: String,
        userNotes: String,
        forceProvider: AIProvider?,
        onDelta: (@Sendable (String) -> Void)?
    ) async -> ProcessingPipeline.SummaryOutcome

    func generateTitle(summary: String, provider: String) async -> String?
}

// MARK: - Meeting Detection

struct MicDetectionEvent: Sendable {
    var appName: String
    var event: MicEvent
    var isRunningInput: Bool
}

/// Observes mic activity from meeting apps (SRP: detection only).
protocol MeetingDetectionService: Sendable {
    func start(onEvent: @escaping @Sendable (MicEvent) -> Void)
    func stop()
    static func displayName(for event: MicEvent) -> String
    static func isIgnored(bundleID: String?) -> Bool
}

// MARK: - Notifications

protocol NotificationService: Sendable {
    func configure(onReadyTapped: @escaping @Sendable (UUID) -> Void)
    func requestAuthorization() async
    func refreshAuthorizationStatus() async -> UNAuthorizationStatus
    func notifyMeetingReady(_ meeting: Meeting)
    func playDetectionChime()
}

import UserNotifications
