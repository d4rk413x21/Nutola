import Foundation

/// Runs the post-recording pipeline and merges results onto the current meeting.
@MainActor
final class ProcessMeetingUseCase {
    let meetingRepository: MeetingRepository
    let processingService: ProcessingService
    let notificationService: NotificationService

    var onProgress: ((UUID, String?) -> Void)?
    var onSummaryUpdate: ((UUID, ProcessingPipeline.SummaryUpdate) -> Void)?
    var onSummaryProgress: ((UUID, SummaryProgress?) -> Void)?

    init(
        meetingRepository: MeetingRepository,
        processingService: ProcessingService,
        notificationService: NotificationService
    ) {
        self.meetingRepository = meetingRepository
        self.processingService = processingService
        self.notificationService = notificationService
    }

    func execute(_ meeting: Meeting) async {
        let id = meeting.id
        NutolaConsoleLog.processing("start \(id.uuidString.prefix(8)) \"\(meeting.title)\" state=\(meeting.state)")
        onProgress?(id, "Starting…")
        var entry = meetingRepository.meeting(id: id) ?? meeting
        entry.state = .processing

        let existing = meetingRepository.transcript(for: id)
        let live = meetingRepository.archive.liveTranscript(for: id)
        if !live.isEmpty {
            let offset = Self.appendOffset(meeting: entry, prior: existing)
            let merged = existing + Self.offsetSegments(live, by: offset)
            meetingRepository.saveTranscript(merged, for: id)
            if existing.isEmpty { entry.speakers = LiveTranscriber.speakers }
            NutolaConsoleLog.processing("merged \(live.count) live segments into transcript")
        }
        meetingRepository.upsert(entry)
        let titleAtEntry = entry.title

        let outcome = await processingService.process(
            meeting: entry,
            archive: meetingRepository.archive,
            onProgress: { [id] stage in
                Task { @MainActor in self.onProgress?(id, stage) }
            },
            onSummary: { [id] update in
                Task { @MainActor in self.applySummaryUpdate(update, for: id) }
            })

        onProgress?(id, nil)
        onSummaryProgress?(id, nil)
        if outcome.state == .ready {
            meetingRepository.archive.removeLiveTranscript(for: id)
        }

        guard var fresh = meetingRepository.meeting(id: id) else { return }
        guard fresh.state == .processing else { return }
        fresh.state = outcome.state
        fresh.notice = outcome.notice
        if let speakers = outcome.speakers {
            fresh.speakers = Self.merging(pipelineSpeakers: speakers, userSpeakers: fresh.speakers)
        }
        if outcome.platformSpeakerAttribution {
            fresh.platformSpeakerAttribution = true
        }
        if let provider = outcome.summaryProvider { fresh.summaryProvider = provider }
        if let title = outcome.generatedTitle, fresh.title == titleAtEntry {
            fresh.title = title
        }
        meetingRepository.upsert(fresh)
        if fresh.state == .ready && !FilePersistence.failures.keys.contains(where: {
            $0.path.hasPrefix(meetingRepository.archive.folder(for: id).path + "/")
        }) {
            NutolaConsoleLog.processing("done \(id.uuidString.prefix(8)) → ready provider=\(fresh.summaryProvider ?? "?")")
            notificationService.notifyMeetingReady(fresh)
        } else {
            NutolaConsoleLog.processing("done \(id.uuidString.prefix(8)) → \(fresh.state) notice=\(fresh.notice ?? "none")")
        }
    }

    private func applySummaryUpdate(_ update: ProcessingPipeline.SummaryUpdate, for id: UUID) {
        switch update {
        case .streaming:
            onSummaryProgress?(id, .streaming)
        case .draftSaved:
            onSummaryProgress?(id, .improving)
        case .done:
            onSummaryProgress?(id, nil)
        }
        onSummaryUpdate?(id, update)
    }

    private static func merging(pipelineSpeakers: [Speaker], userSpeakers: [Speaker]) -> [Speaker] {
        pipelineSpeakers.map { pipelineSpeaker in
            if let renamed = userSpeakers.first(where: { $0.id == pipelineSpeaker.id }) {
                var kept = pipelineSpeaker
                kept.name = renamed.name
                return kept
            }
            return pipelineSpeaker
        }
    }

    private static func appendOffset(meeting: Meeting, prior: [TranscriptSegment]) -> TimeInterval {
        guard !prior.isEmpty else { return 0 }
        return max(meeting.duration, prior.map(\.end).max() ?? 0)
    }

    private static func offsetSegments(
        _ segments: [TranscriptSegment], by offset: TimeInterval
    ) -> [TranscriptSegment] {
        segments.map { seg in
            var s = seg
            s.start += offset
            s.end += offset
            return s
        }
    }
}

/// Re-runs summary generation for an existing transcript.
@MainActor
final class RegenerateSummaryUseCase {
    let meetingRepository: MeetingRepository
    let processingService: ProcessingService

    var onProgress: ((UUID, String?) -> Void)?
    var onStreamingSummary: ((UUID, String?) -> Void)?
    var onSummaryProgress: ((UUID, SummaryProgress?) -> Void)?

    init(meetingRepository: MeetingRepository, processingService: ProcessingService) {
        self.meetingRepository = meetingRepository
        self.processingService = processingService
    }

    func execute(meetingID: UUID, templateName: String? = nil, forceProvider: AIProvider? = nil) async {
        guard var entry = meetingRepository.meeting(id: meetingID) else { return }
        NutolaConsoleLog.processing(
            "regenerate \(meetingID.uuidString.prefix(8)) template=\(templateName ?? entry.templateName ?? "default")"
                + (forceProvider.map { " provider=\($0.displayName)" } ?? ""))
        if let templateName {
            entry.templateName = templateName
            meetingRepository.upsert(entry)
        }
        onProgress?(meetingID, "Summarizing…")
        onSummaryProgress?(meetingID, .streaming)
        onStreamingSummary?(meetingID, "")

        let segments = meetingRepository.transcript(for: meetingID)
        let rawText = TranscriptFormatter.plainText(segments, speakers: entry.speakers)
        var text = rawText
        if AppSettings.fillerRemoval {
            text = FillerWordRemover.clean(text)
        }
        let dictionary = PersonalDictionaryStore()
        if dictionary.hasAny {
            text = dictionary.apply(to: text)
        }
        let userNotes = meetingRepository.sideNotes(for: meetingID)
        let titleAtEntry = entry.title

        let outcome = await processingService.summarize(
            meeting: entry, transcript: text, userNotes: userNotes, forceProvider: forceProvider
        ) { [meetingID] delta in
            Task { @MainActor in self.onStreamingSummary?(meetingID, delta) }
        }

        var generatedTitle: String?
        if case .success(let summary, let provider) = outcome,
           entry.calendarEventTitle == nil {
            onProgress?(meetingID, "Naming the meeting…")
            generatedTitle = await processingService.generateTitle(summary: summary, provider: provider)
        }
        onProgress?(meetingID, nil)
        onStreamingSummary?(meetingID, nil)
        onSummaryProgress?(meetingID, nil)

        guard var fresh = meetingRepository.meeting(id: meetingID) else { return }
        switch outcome {
        case .success(let summary, let provider):
            let roster = meetingRepository.archive.zoomRoster(for: meetingID)
            let annotated = AdditionalParticipantsAnnotator.annotation(
                roster: roster,
                attendees: entry.attendees)
                .map { summary + "\n\n" + $0 }
                ?? summary
            meetingRepository.saveSummary(annotated, for: meetingID)
            fresh.summaryProvider = provider
            fresh.notice = nil
            if let generatedTitle, fresh.title == titleAtEntry {
                fresh.title = generatedTitle
            }
        case .failure(let why):
            fresh.notice = why
            NutolaConsoleLog.processing("regenerate failed — \(why)")
        }
        meetingRepository.upsert(fresh)
    }
}

/// Retries failed processing or regenerates summary for ready meetings.
@MainActor
struct RetryMeetingUseCase {
    let meetingRepository: MeetingRepository
    let processMeeting: ProcessMeetingUseCase
    let regenerateSummary: RegenerateSummaryUseCase

    func execute(meetingID: UUID) async {
        guard var meeting = meetingRepository.meeting(id: meetingID) else { return }
        NutolaConsoleLog.processing("retry \(meetingID.uuidString.prefix(8)) state=\(meeting.state)")
        if meeting.state == .failed || meetingRepository.transcript(for: meetingID).isEmpty {
            meeting.notice = nil
            meetingRepository.upsert(meeting)
            await processMeeting.execute(meeting)
        } else {
            await regenerateSummary.execute(meetingID: meetingID)
        }
    }
}
