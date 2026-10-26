import Foundation

/// A per-conferencing-app speaker tracker that polls the client's UI during
/// recording and reports who is speaking, for attributing system-audio
/// transcript segments to named participants instead of generic
/// "Speaker 1..N".
///
/// Zoom reads native speaker tiles; Google Meet in Chrome reads caption identities.
/// Unsupported clients keep the on-device diarization path.
protocol PlatformSpeakerTracker: AnyObject, Sendable {
    /// Called on the main queue whenever the active remote speaker changes.
    @MainActor var onActiveSpeaker: (@MainActor (String?) -> Void)? { get set }

    /// Called on the main queue when the local participant's Zoom mute state changes.
    /// True = muted (stop mic capture), false = unmuted (resume mic capture).
    @MainActor var onLocalMuteChanged: (@MainActor (Bool) -> Void)? { get set }

    /// Thread-safe snapshot of the active speaker name at elapsed time `t`,
    /// for attributing live system-audio segments.
    func speakerAt(_ elapsed: TimeInterval) -> String?

    /// Thread-safe snapshot of the current participant roster.
    func currentRoster() -> [String]
    func isLocalParticipant(_ name: String) -> Bool
    var statusMessage: String? { get }

    func start()
    func stop()
}

extension PlatformSpeakerTracker {
    func isLocalParticipant(_ name: String) -> Bool { ZoomActiveSpeakerReader.isLocalParticipant(name) }
    var statusMessage: String? { nil }
}

enum SpeakerTrackingTarget: Sendable, Equatable {
    case zoom
    case googleMeetChrome
}

/// Creates the tracker for a supported meeting source.
enum PlatformSpeakerTrackerFactory {
    @MainActor static func make(
        target: SpeakerTrackingTarget,
        meetingID: UUID,
        archive: MeetingArchive,
        startDate: Date,
        elapsedOffset: TimeInterval
    ) -> PlatformSpeakerTracker {
        switch target {
        case .zoom:
            return ZoomSpeakerTracker(
                meetingID: meetingID,
                archive: archive,
                startDate: startDate,
                elapsedOffset: elapsedOffset)
        case .googleMeetChrome:
            return GoogleMeetSpeakerTracker(meetingID: meetingID, archive: archive,
                                            startDate: startDate, elapsedOffset: elapsedOffset)
        }
    }
}
