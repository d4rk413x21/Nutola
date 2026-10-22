import Foundation

// MARK: - Start Recording

/// Creates a meeting folder, enriches metadata from calendar/folders, and starts capture.
@MainActor
struct StartRecordingUseCase {
    let recordingService: RecordingService
    let meetingRepository: MeetingRepository
    let folderRepository: FolderRepository
    let calendarRepository: CalendarRepository
    let settings: SettingsRepository
    let templateOverrides: TemplateOverrideRepository
    let availableTemplateNames: () -> [String]

    func execute(
        sourceApp: String? = nil,
        calendarEvent: CalendarEventSummary? = nil
    ) async -> Result<RecordingSessionHandle, RecordingError> {
        await recordingService.startRecording(
            sourceApp: sourceApp,
            calendarEvent: calendarEvent,
            meetingRepository: meetingRepository,
            folderRepository: folderRepository,
            calendarRepository: calendarRepository,
            settings: settings,
            templateOverrides: templateOverrides,
            availableTemplateNames: availableTemplateNames)
    }
}

// MARK: - Stop Recording

@MainActor
struct StopRecordingUseCase {
    let recordingService: RecordingService
    let meetingRepository: MeetingRepository
    let processMeeting: ProcessMeetingUseCase

    func execute() async -> Meeting? {
        guard let (session, meeting) = await recordingService.stop() else { return nil }
        var fresh = meetingRepository.meeting(id: meeting.id) ?? meeting
        fresh.duration = session.elapsed
        meetingRepository.upsert(fresh)
        await processMeeting.execute(fresh)
        return fresh
    }
}

// MARK: - Discard Recording

@MainActor
struct DiscardRecordingUseCase {
    let recordingService: RecordingService
    let meetingRepository: MeetingRepository

    func execute() {
        guard let (_, meeting) = recordingService.discard() else { return }
        meetingRepository.delete(id: meeting.id)
    }
}

// MARK: - Continue Recording

@MainActor
struct ContinueRecordingUseCase {
    let recordingService: RecordingService
    let meetingRepository: MeetingRepository

    func execute(meetingID: UUID) async -> Result<RecordingSessionHandle, RecordingError> {
        await recordingService.continueRecording(
            meetingID: meetingID,
            meetingRepository: meetingRepository)
    }
}

// MARK: - Prepare Meeting

@MainActor
struct PrepareMeetingUseCase {
    let meetingRepository: MeetingRepository
    let folderRepository: FolderRepository
    let settings: SettingsRepository
    let templateOverrides: TemplateOverrideRepository
    let availableTemplateNames: () -> [String]

    func execute(calendarEvent: CalendarEventSummary) -> Result<Meeting, RecordingError> {
        var meeting = Meeting(title: calendarEvent.title, createdAt: Date())
        meeting.state = .prep
        meeting.calendarEventTitle = calendarEvent.title
        meeting.attendees = calendarEvent.attendees
        meeting.calendarEventID = calendarEvent.id
        meeting.calendarEventStart = calendarEvent.start
        meeting.calendarEventEnd = calendarEvent.end
        meeting.templateName = settings.smartTemplatesEnabled
            ? MeetingTemplateResolver.templateName(
                for: MeetingTemplateResolver.resolve(for: meeting))
            : settings.defaultTemplate
        // Per-event override wins over both the default and the smart template.
        if let override = templateOverrides.templateName(
            forEventID: calendarEvent.id, available: availableTemplateNames()) {
            meeting.templateName = override
        }

        if let title = meeting.calendarEventTitle,
           let folder = folderRepository.folder(forTitle: title) {
            meeting.folderID = folder.id
        }

        let archive = meetingRepository.archive
        do {
            try archive.createFolder(for: meeting.id)
        } catch {
            return .failure(.archiveCreationFailed(error.localizedDescription))
        }
        meetingRepository.upsert(meeting)
        return .success(meeting)
    }
}

// MARK: - Open Calendar Event

@MainActor
struct OpenCalendarEventUseCase {
    let meetingRepository: MeetingRepository
    let calendarRepository: CalendarRepository
    let prepareMeeting: PrepareMeetingUseCase

    enum Outcome: Equatable {
        case openExisting(UUID)
        case prepared(UUID)
        case failed
    }

    func execute(_ event: CalendarEventSummary) async -> Outcome {
        if let existing = calendarRepository.meetingForCalendarEvent(
            event, in: meetingRepository.meetings) {
            return .openExisting(existing.id)
        }
        switch prepareMeeting.execute(calendarEvent: event) {
        case .success(let meeting):
            return .prepared(meeting.id)
        case .failure:
            return .failed
        }
    }
}
