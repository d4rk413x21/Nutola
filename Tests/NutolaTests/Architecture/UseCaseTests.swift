import Foundation
import Testing
@testable import Nutola

@MainActor
struct UseCaseTests {
    // MARK: - Prepare

    @Test func testPrepareMeetingCreatesPrepStateMeeting() {
        let meetings = MockMeetingRepository()
        let folders = MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root))
        let settings = MockSettingsRepository()
        let useCase = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: folders,
            settings: settings,
            templateOverrides: TemplateOverrideStore(root: meetings.archive.root),
            availableTemplateNames: { [] })

        let result = useCase.execute(calendarEvent: ArchitectureFixtures.sampleCalendarEvent())
        guard case .success(let meeting) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(meeting.state == .prep)
        #expect(meeting.title == "Weekly Standup")
        #expect(meeting.calendarEventID == "evt-1")
        #expect(meetings.meetings.count == 1)
    }

    @Test func testPrepareMeetingUsesDefaultTemplate() {
        let meetings = MockMeetingRepository()
        var settings = MockSettingsRepository()
        settings.defaultTemplate = "1-on-1"
        let useCase = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root)),
            settings: settings,
            templateOverrides: TemplateOverrideStore(root: meetings.archive.root),
            availableTemplateNames: { [] })

        guard case .success(let meeting) = useCase.execute(
            calendarEvent: ArchitectureFixtures.sampleCalendarEvent()) else {
            Issue.record("Expected success")
            return
        }
        #expect(meeting.templateName == "1-on-1")
    }

    @Test func testPrepareMeetingUsesPerEventOverrideWhenAvailable() {
        let meetings = MockMeetingRepository()
        let settings = MockSettingsRepository()
        let overrides = TemplateOverrideStore(root: meetings.archive.root)
        let event = ArchitectureFixtures.sampleCalendarEvent(id: "evt-77", title: "Interview with Alex")
        overrides.set(eventID: event.id, templateName: "Interview")
        let useCase = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root)),
            settings: settings,
            templateOverrides: overrides,
            availableTemplateNames: { ["Meeting Notes", "Interview", "1-on-1"] })

        guard case .success(let meeting) = useCase.execute(calendarEvent: event) else {
            Issue.record("Expected success")
            return
        }
        // Per-event assignment wins over the default template.
        #expect(meeting.templateName == "Interview")
    }

    @Test func testPrepareMeetingIgnoresOverrideWhenTemplateDeleted() {
        let meetings = MockMeetingRepository()
        var settings = MockSettingsRepository()
        settings.defaultTemplate = "Meeting Notes"
        let overrides = TemplateOverrideStore(root: meetings.archive.root)
        let event = ArchitectureFixtures.sampleCalendarEvent(id: "evt-88", title: "Standup")
        overrides.set(eventID: event.id, templateName: "Gone")
        let useCase = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root)),
            settings: settings,
            templateOverrides: overrides,
            availableTemplateNames: { ["Meeting Notes"] }) // "Gone" no longer exists

        guard case .success(let meeting) = useCase.execute(calendarEvent: event) else {
            Issue.record("Expected success")
            return
        }
        // Stale override is pruned on read; default applies.
        #expect(meeting.templateName == "Meeting Notes")
        #expect(overrides.overrides[event.id] == nil, "stale override should have been pruned")
    }

    // MARK: - Open calendar event

    @Test func testOpenCalendarEventReturnsExistingMeeting() async {
        let meetings = MockMeetingRepository()
        let event = ArchitectureFixtures.sampleCalendarEvent()
        var existing = Meeting(title: "Prior", createdAt: Date())
        existing.calendarEventID = event.id
        existing.calendarEventStart = event.start
        try? meetings.archive.createFolder(for: existing.id)
        meetings.upsert(existing)

        let calendar = MockCalendarRepository()
        let prepare = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root)),
            settings: MockSettingsRepository(),
            templateOverrides: TemplateOverrideStore(root: meetings.archive.root),
            availableTemplateNames: { [] })
        let useCase = OpenCalendarEventUseCase(
            meetingRepository: meetings,
            calendarRepository: calendar,
            prepareMeeting: prepare)

        let outcome = await useCase.execute(event)
        #expect(outcome == .openExisting(existing.id))
    }

    @Test func testOpenCalendarEventPreparesWhenMissing() async {
        let meetings = MockMeetingRepository()
        let calendar = MockCalendarRepository()
        let prepare = PrepareMeetingUseCase(
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root)),
            settings: MockSettingsRepository(),
            templateOverrides: TemplateOverrideStore(root: meetings.archive.root),
            availableTemplateNames: { [] })
        let useCase = OpenCalendarEventUseCase(
            meetingRepository: meetings,
            calendarRepository: calendar,
            prepareMeeting: prepare)

        let outcome = await useCase.execute(ArchitectureFixtures.sampleCalendarEvent())
        guard case .prepared(let id) = outcome else {
            Issue.record("Expected prepared")
            return
        }
        #expect(meetings.meeting(id: id)?.state == .prep)
    }

    // MARK: - Process

    @Test func testProcessMeetingUpdatesStateAndNotifies() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Test", createdAt: Date())
        meeting.state = .processing
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let notifications = MockNotificationService()
        var progressStages: [String] = []
        let processing = MockProcessingService()
        processing.outcome = ProcessingPipeline.Outcome(state: .ready)

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: notifications)
        useCase.onProgress = { _, stage in
            if let stage { progressStages.append(stage) }
        }

        await useCase.execute(meeting)

        #expect(meetings.meeting(id: meeting.id)?.state == .ready)
        #expect(notifications.readyMeetings.count == 1)
        #expect(!(progressStages.isEmpty))
    }

    @Test func testProcessMeetingMergesLiveTranscriptBeforePipeline() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Live", createdAt: Date())
        meeting.state = .processing
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let live = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Hello"),
            TranscriptSegment(speakerID: "s1", start: 1, end: 2, text: "Hi"),
        ]
        meetings.archive.saveLiveTranscript(live, for: meeting.id)

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: MockProcessingService(),
            notificationService: MockNotificationService())

        await useCase.execute(meeting)

        let saved = meetings.transcript(for: meeting.id)
        #expect(saved.count == 2)
        #expect(saved.map(\.text) == ["Hello", "Hi"])
        #expect(meetings.archive.liveTranscript(for: meeting.id).isEmpty)
    }

    @Test func testProcessMeetingPreservesUserSpeakerRenames() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Rename", createdAt: Date())
        meeting.state = .processing
        meeting.speakers = [Speaker(id: "s1", name: "Alice")]
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let processing = MockProcessingService()
        processing.outcome = ProcessingPipeline.Outcome(
            state: .ready,
            speakers: [Speaker(id: "s1", name: "Speaker 1")])

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())

        await useCase.execute(meeting)

        #expect(meetings.meeting(id: meeting.id)?.speakers.first?.name == "Alice")
    }

    @Test func testProcessMeetingDoesNotNotifyWhenFailed() async {
        let meetings = MockMeetingRepository()
        let meeting = Meeting(title: "Fail", createdAt: Date())
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let notifications = MockNotificationService()
        let processing = MockProcessingService()
        processing.outcome = ProcessingPipeline.Outcome(state: .failed, notice: "No audio")

        let useCase = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: notifications)

        await useCase.execute(meeting)

        #expect(meetings.meeting(id: meeting.id)?.state == .failed)
        #expect(notifications.readyMeetings.isEmpty)
    }

    // MARK: - Regenerate

    @Test func testRegenerateSummarySavesMarkdownAndTitle() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Untitled", createdAt: Date())
        meeting.state = .ready
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)
        meetings.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "We shipped it.")],
            for: meeting.id)

        let processing = MockProcessingService()
        let useCase = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: processing)

        var streamed: [String?] = []
        useCase.onStreamingSummary = { _, text in streamed.append(text) }

        await useCase.execute(meetingID: meeting.id)

        #expect(meetings.summary(for: meeting.id) == "# Notes\n\nTest summary")
        #expect(meetings.meeting(id: meeting.id)?.title == "Test Meeting Title")
        #expect(meetings.meeting(id: meeting.id)?.summaryProvider == "apple")
        #expect(streamed.contains("partial"))
    }

    @Test func testRegenerateSummaryKeepsCalendarTitle() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Standup", createdAt: Date())
        meeting.calendarEventTitle = "Standup"
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)
        meetings.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Done.")],
            for: meeting.id)

        let useCase = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: MockProcessingService())

        await useCase.execute(meetingID: meeting.id)

        #expect(meetings.meeting(id: meeting.id)?.title == "Standup")
    }

    // MARK: - Retry

    @Test func testRetryFailedMeetingRunsProcess() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Failed", createdAt: Date())
        meeting.state = .failed
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)

        let processing = MockProcessingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())
        let regenerate = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: processing)
        let retry = RetryMeetingUseCase(
            meetingRepository: meetings,
            processMeeting: processUC,
            regenerateSummary: regenerate)

        await retry.execute(meetingID: meeting.id)

        #expect(processing.processCallCount == 1)
        #expect(processing.summarizeCallCount == 0)
        #expect(meetings.meeting(id: meeting.id)?.state == .ready)
    }

    @Test func testRetryReadyMeetingRegeneratesSummary() async {
        let meetings = MockMeetingRepository()
        var meeting = Meeting(title: "Ready", createdAt: Date())
        meeting.state = .ready
        try? meetings.archive.createFolder(for: meeting.id)
        meetings.upsert(meeting)
        meetings.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Notes.")],
            for: meeting.id)

        let processing = MockProcessingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())
        let regenerate = RegenerateSummaryUseCase(
            meetingRepository: meetings,
            processingService: processing)
        let retry = RetryMeetingUseCase(
            meetingRepository: meetings,
            processMeeting: processUC,
            regenerateSummary: regenerate)

        await retry.execute(meetingID: meeting.id)

        #expect(processing.processCallCount == 0)
        #expect(processing.summarizeCallCount == 1)
    }
}
