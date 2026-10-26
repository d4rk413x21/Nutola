import Foundation
import Testing
@testable import Nutola

@MainActor
struct MeetingResumeTests {
    @Test func testMeetingForCalendarEventMatchesInstanceStart() {
        let calendar = CalendarStore()
        let event = ArchitectureFixtures.sampleCalendarEvent(id: "evt-1", title: "All Hands")
        var otherDay = Meeting(title: "Old", createdAt: Date())
        otherDay.calendarEventID = "evt-1"
        otherDay.calendarEventStart = event.start.addingTimeInterval(-86_400)
        var today = Meeting(title: "Today", createdAt: Date())
        today.calendarEventID = "evt-1"
        today.calendarEventStart = event.start

        let match = calendar.meetingForCalendarEvent(event, in: [otherDay, today])
        #expect(match?.id == today.id)
    }

    @Test func testMeetingForCalendarEventPrefersLongestRecording() {
        let calendar = CalendarStore()
        let event = ArchitectureFixtures.sampleCalendarEvent()
        var brief = Meeting(title: "Brief", createdAt: Date())
        brief.calendarEventID = event.id
        brief.calendarEventStart = event.start
        brief.duration = 120
        var longest = Meeting(title: "Long", createdAt: Date().addingTimeInterval(60))
        longest.calendarEventID = event.id
        longest.calendarEventStart = event.start
        longest.duration = 1800

        let match = calendar.meetingForCalendarEvent(event, in: [brief, longest])
        #expect(match?.id == longest.id)
    }

    @Test func testCanResumeRecordingIncludesReadyPrepAndProcessingOrphan() {
        var prep = Meeting(title: "Prep", createdAt: Date())
        prep.state = .prep
        var ready = Meeting(title: "Ready", createdAt: Date())
        ready.state = .ready
        var recording = Meeting(title: "Recording", createdAt: Date())
        recording.state = .recording
        // A crash-orphan being finalized has no live RecordingSession, so a
        // detection-driven start on the same launch must be able to resume it
        // instead of creating a duplicate meeting for the same calendar event.
        var processingOrphan = Meeting(title: "Finalizing", createdAt: Date())
        processingOrphan.state = .processing

        #expect(prep.canResumeRecording(isRecording: false))
        #expect(ready.canResumeRecording(isRecording: false))
        #expect(!(recording.canResumeRecording(isRecording: false)))
        #expect(processingOrphan.canResumeRecording(isRecording: false))
        // Never resumable while a session is actually live.
        #expect(!(processingOrphan.canResumeRecording(isRecording: true)))
        #expect(!(ready.canResumeRecording(isRecording: true)))
    }

    @Test func testProcessMeetingSkipsWhenRecordingResumed() async {
        let meetings = MockMeetingRepository()
        let meeting = Meeting(title: "Resumed", createdAt: Date())
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let processing = DelayedMockProcessingService()
        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())

        let task = Task { await useCase.execute(meeting) }
        try? await Task.sleep(for: .milliseconds(20))
        var resumed = meetings.meeting(id: meeting.id)!
        resumed.state = .recording
        meetings.upsert(resumed)
        await task.value

        #expect(meetings.meeting(id: meeting.id)?.state == .recording)
    }
}

private final class DelayedMockProcessingService: ProcessingService, @unchecked Sendable {
    func process(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void,
        onSummary: @escaping @Sendable (ProcessingPipeline.SummaryUpdate) -> Void
    ) async -> ProcessingPipeline.Outcome {
        try? await Task.sleep(for: .milliseconds(50))
        onProgress("Done")
        onSummary(.done)
        return ProcessingPipeline.Outcome(state: .ready)
    }

    func summarize(
        meeting: Meeting,
        transcript: String,
        userNotes: String,
        forceProvider: AIProvider? = nil,
        onDelta: (@Sendable (String) -> Void)?
    ) async -> ProcessingPipeline.SummaryOutcome {
        .success("", provider: "apple")
    }

    func generateTitle(summary: String, provider: String) async -> String? { nil }
}
