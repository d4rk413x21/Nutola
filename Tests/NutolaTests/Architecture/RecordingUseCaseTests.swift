import Foundation
import Testing
@testable import Nutola

@MainActor
struct RecordingUseCaseTests {
    @Test func testStopRecordingPersistsDurationAndProcesses() async {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        let handle = ArchitectureFixtures.recordingHandle(repository: meetings)
        recording.stopPair = (handle.session, handle.meeting)

        let processing = MockProcessingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())
        let stop = StopRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings,
            processMeeting: processUC)

        let result = await stop.execute()

        #expect(recording.stopCallCount == 1)
        #expect(result != nil)
        #expect(processing.processCallCount == 1)
        #expect(meetings.meeting(id: handle.meeting.id)?.duration == 0)
    }

    @Test func testStopRecordingReturnsNilWhenNothingActive() async {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: MockProcessingService(),
            notificationService: MockNotificationService())
        let stop = StopRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings,
            processMeeting: processUC)

        let result = await stop.execute()
        #expect(result == nil)
        #expect(recording.stopCallCount == 1)
    }

    @Test func testDiscardRecordingDeletesMeeting() {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        let handle = ArchitectureFixtures.recordingHandle(repository: meetings)
        recording.discardPair = (handle.session, handle.meeting)

        let discard = DiscardRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings)

        discard.execute()

        #expect(recording.discardCallCount == 1)
        #expect(meetings.meeting(id: handle.meeting.id) == nil)
    }

    @Test func testStartRecordingUseCaseForwardsToService() async {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        let handle = ArchitectureFixtures.recordingHandle(repository: meetings)
        recording.startResult = .success(handle)

        let start = StartRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(archive: FolderArchive(root: meetings.archive.root)),
            calendarRepository: MockCalendarRepository(),
            settings: MockSettingsRepository(),
            templateOverrides: TemplateOverrideStore(root: meetings.archive.root),
            availableTemplateNames: { [] })

        let result = await start.execute(sourceApp: "Zoom", calendarEvent: nil)

        guard case .success(let got) = result else {
            Issue.record("Expected success")
            return
        }
        #expect(got.meeting.id == handle.meeting.id)
        #expect(recording.startCallCount == 1)
    }

    @Test func testContinueRecordingReturnsFailureWhenNotAllowed() async {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        recording.continueResult = .failure(.cannotContinue)

        let useCase = ContinueRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings)

        let result = await useCase.execute(meetingID: UUID())
        guard case .failure(let error) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(error == .cannotContinue)
    }
}
