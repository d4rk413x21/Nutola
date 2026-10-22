import XCTest
@testable import Nutola

@MainActor
final class RecordingUseCaseTests: XCTestCase {
    func testStopRecordingPersistsDurationAndProcesses() async {
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

        XCTAssertEqual(recording.stopCallCount, 1)
        XCTAssertNotNil(result)
        XCTAssertEqual(processing.processCallCount, 1)
        XCTAssertEqual(meetings.meeting(id: handle.meeting.id)?.duration, 0)
    }

    func testStopAwaitsCaptureFinalizationBeforeProcessing() async {
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

        _ = await stop.execute()
        XCTAssertEqual(recording.stopCallCount, 1)
        XCTAssertEqual(processing.processCallCount, 1)
    }

    func testStopRecordingReturnsNilWhenNothingActive() async {
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
        XCTAssertNil(result)
        XCTAssertEqual(recording.stopCallCount, 1)
    }

    func testDiscardRecordingDeletesMeeting() {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        let handle = ArchitectureFixtures.recordingHandle(repository: meetings)
        recording.discardPair = (handle.session, handle.meeting)

        let discard = DiscardRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings)

        discard.execute()

        XCTAssertEqual(recording.discardCallCount, 1)
        XCTAssertNil(meetings.meeting(id: handle.meeting.id))
    }

    func testStartRecordingUseCaseForwardsToService() async {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        let handle = ArchitectureFixtures.recordingHandle(repository: meetings)
        recording.startResult = .success(handle)

        let start = StartRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings,
            folderRepository: MeetingFolderStore(),
            calendarRepository: MockCalendarRepository(),
            settings: MockSettingsRepository(),
            templateOverrides: TemplateOverrideStore(),
            availableTemplateNames: { [] })

        let result = await start.execute(sourceApp: "Zoom", calendarEvent: nil)

        guard case .success(let got) = result else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(got.meeting.id, handle.meeting.id)
        XCTAssertEqual(recording.startCallCount, 1)
    }

    func testContinueRecordingReturnsFailureWhenNotAllowed() async {
        let meetings = MockMeetingRepository()
        let recording = MockRecordingService()
        recording.continueResult = .failure(.cannotContinue)

        let useCase = ContinueRecordingUseCase(
            recordingService: recording,
            meetingRepository: meetings)

        let result = await useCase.execute(meetingID: UUID())
        guard case .failure(let error) = result else {
            return XCTFail("Expected failure")
        }
        XCTAssertEqual(error, .cannotContinue)
    }
}
