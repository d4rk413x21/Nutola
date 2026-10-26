import Foundation
import UserNotifications
import XCTest
@testable import Nutola

// MARK: - Meeting repository

@MainActor
final class MockMeetingRepository: MeetingRepository {
    var meetings: [Meeting] = []
    let archive: MeetingArchive

    init(archive: MeetingArchive = MeetingArchive(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("NutolaTests-\(UUID().uuidString)", isDirectory: true))) {
        self.archive = archive
    }

    func reload() { meetings = archive.allMeetings() }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    @discardableResult
    func upsert(_ meeting: Meeting) -> Meeting {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.append(meeting)
        }
        try? archive.save(meeting)
        return meeting
    }

    func delete(id: UUID) {
        try? archive.delete(id: id)
        meetings.removeAll { $0.id == id }
    }

    func transcript(for id: UUID) -> [TranscriptSegment] { archive.transcript(for: id) }
    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        try? archive.saveTranscript(segments, for: id)
    }
    func summary(for id: UUID) -> String { archive.summary(for: id) }
    func saveSummary(_ markdown: String, for id: UUID) { try? archive.saveSummary(markdown, for: id) }
    func sideNotes(for id: UUID) -> String { archive.sideNotes(for: id) }
    func saveSideNotes(_ text: String, for id: UUID) { try? archive.saveSideNotes(text, for: id) }
    func renameSpeaker(meetingID: UUID, speakerID: String, to newName: String) {
        guard var m = meeting(id: meetingID),
              let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        m.speakers[i].name = newName
        upsert(m)
    }
}

// MARK: - Calendar repository

@MainActor
final class MockCalendarRepository: CalendarRepository {
    var agenda: [CalendarAgendaDay] = []
    var isLoading = false
    var lastRefresh: Date?
    var fetchHorizonDays = 30
    var nextUpcomingEvent: CalendarEventSummary?
    var currentEventResult: CalendarEventSummary?

    func refreshAgenda(now: Date, horizonDays: Int?) async {
        lastRefresh = now
    }

    func currentEvent(at now: Date, sourceApp: String?) async -> CalendarEventSummary? {
        currentEventResult
    }

    func countdownText(for event: CalendarEventSummary) -> String? { "in 5m" }

    func meetingForCalendarEvent(_ event: CalendarEventSummary, in meetings: [Meeting]) -> Meeting? {
        meetings
            .filter { $0.calendarEventID == event.id && $0.calendarEventStart == event.start }
            .max { a, b in
                if a.duration != b.duration { return a.duration < b.duration }
                return a.createdAt > b.createdAt
            }
    }
}

// MARK: - Settings

struct MockSettingsRepository: SettingsRepository {
    var autoRecord = false
    var detectMeetings = false
    var identifySpeakers = true
    var useCalendar = false
    var autoStopRecording = false
    var defaultTemplate = "Meeting Notes"
    var preferredAIProvider: AIProvider = .apple
    var preferClaudeSummaries = false
    var showLiveRecordingCard = true
    var smartTemplatesEnabled = false
}

// MARK: - Processing

final class MockProcessingService: ProcessingService, @unchecked Sendable {
    var outcome = ProcessingPipeline.Outcome(state: .ready)
    var summarizeResult: ProcessingPipeline.SummaryOutcome =
        .success("# Notes\n\nTest summary", provider: "apple")
    var generatedTitle: String? = "Test Meeting Title"
    private(set) var processCallCount = 0
    private(set) var summarizeCallCount = 0
    private(set) var lastSummarizeTranscript: String?

    func process(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void,
        onSummary: @escaping @Sendable (ProcessingPipeline.SummaryUpdate) -> Void
    ) async -> ProcessingPipeline.Outcome {
        processCallCount += 1
        onProgress("Done")
        onSummary(.done)
        return outcome
    }

    func summarize(
        meeting: Meeting,
        transcript: String,
        userNotes: String,
        forceProvider: AIProvider? = nil,
        onDelta: (@Sendable (String) -> Void)?
    ) async -> ProcessingPipeline.SummaryOutcome {
        summarizeCallCount += 1
        lastSummarizeTranscript = transcript
        if let onDelta { onDelta("partial") }
        return summarizeResult
    }

    func generateTitle(summary: String, provider: String) async -> String? {
        generatedTitle
    }
}

// MARK: - Notifications

final class MockNotificationService: NotificationService, @unchecked Sendable {
    var readyMeetings: [Meeting] = []

    func configure(onReadyTapped: @escaping @Sendable (UUID) -> Void) {}
    func requestAuthorization() async {}
    func refreshAuthorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func notifyMeetingReady(_ meeting: Meeting) { readyMeetings.append(meeting) }
    func playDetectionChime() {}
}

// MARK: - Recording

@MainActor
final class MockRecordingService: RecordingService {
    var isRecording = false
    var isStartingRecording = false
    private(set) var currentSession: RecordingSession?
    private(set) var recordingMeeting: Meeting?

    var startResult: Result<RecordingSessionHandle, RecordingError>?
    var continueResult: Result<RecordingSessionHandle, RecordingError>?
    var stopPair: (RecordingSession, Meeting)?
    var discardPair: (RecordingSession, Meeting)?
    private(set) var startCallCount = 0
    private(set) var continueCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var discardCallCount = 0

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
        startCallCount += 1
        guard let startResult else { return .failure(.alreadyRecording) }
        if case .success(let handle) = startResult {
            adopt(handle)
        }
        return startResult
    }

    func continueRecording(
        meetingID: UUID,
        meetingRepository: MeetingRepository
    ) async -> Result<RecordingSessionHandle, RecordingError> {
        continueCallCount += 1
        guard let continueResult else { return .failure(.cannotContinue) }
        if case .success(let handle) = continueResult {
            adopt(handle)
        }
        return continueResult
    }

    func stop() async -> (session: RecordingSession, meeting: Meeting)? {
        stopCallCount += 1
        guard let stopPair else { return nil }
        clear()
        return stopPair
    }

    func discard() -> (session: RecordingSession, meeting: Meeting)? {
        discardCallCount += 1
        guard let discardPair else { return nil }
        clear()
        return discardPair
    }

    func prepareForTermination(meetingRepository: MeetingRepository) async {
        // Test-only termination: do not launch an unstructured async stop.
        clear()
    }

    func adopt(_ handle: RecordingSessionHandle) {
        currentSession = handle.session
        recordingMeeting = handle.meeting
        isRecording = true
    }

    func clear() {
        currentSession = nil
        recordingMeeting = nil
        isRecording = false
    }
}

// MARK: - Detection

final class MockMeetingDetectionService: MeetingDetectionService, @unchecked Sendable {
    private(set) var handler: (@Sendable (MicEvent) -> Void)?
    private(set) var isRunning = false

    func start(onEvent: @escaping @Sendable (MicEvent) -> Void) {
        handler = onEvent
        isRunning = true
    }

    func stop() {
        handler = nil
        isRunning = false
    }

    func emit(_ event: MicEvent) {
        handler?(event)
    }

    static func displayName(for event: MicEvent) -> String {
        event.appName ?? "Unknown"
    }

    static func isIgnored(bundleID: String?) -> Bool { false }
}

// MARK: - Fixtures

enum ArchitectureFixtures {
    @MainActor
    static func sampleCalendarEvent(
        id: String = "evt-1",
        title: String = "Weekly Standup"
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            id: id,
            title: title,
            start: Date(),
            end: Date().addingTimeInterval(3600),
            location: nil,
            attendees: ["Alice", "Bob"],
            conferenceURL: nil,
            calendarID: nil,
            calendarTitle: "Work",
            calendarColor: .gray)
    }

    @MainActor
    static func recordingHandle(
        repository: MockMeetingRepository,
        title: String = "Recording"
    ) -> RecordingSessionHandle {
        let meeting = Meeting(title: title, createdAt: Date())
        try? repository.archive.createFolder(for: meeting.id)
        repository.upsert(meeting)
        let session = RecordingSession(meetingID: meeting.id, archive: repository.archive)
        return RecordingSessionHandle(session: session, meeting: meeting)
    }

    static func micEvent(pid: pid_t = 42, running: Bool = true) -> MicEvent {
        MicEvent(pid: pid, bundleID: "us.zoom.xos", appName: "Zoom", isRunningInput: running)
    }
}
