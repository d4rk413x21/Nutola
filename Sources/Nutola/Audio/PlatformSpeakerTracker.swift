import Foundation

/// A per-conferencing-app speaker tracker that polls the client's UI during
/// recording and reports who is speaking, for attributing system-audio
/// transcript segments to named participants instead of generic
/// "Speaker 1..N".
///
/// Today only Zoom is implemented (`ZoomSpeakerTracker`); Meet/Teams/FaceTime
/// fall back to `NoopSpeakerTracker` (diarization-only). Adding a platform is
/// a new conformer + a line in `PlatformSpeakerTrackerFactory.forApp(_:)`,
/// not a change to `RecordingSession`.
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

    func start()
    func stop()
}

/// Chooses a speaker tracker for the detected source app. Returns a no-op
/// tracker for platforms without an AX/caption reader, so `RecordingSession`
/// always has *something* conforming and never nil-checks the platform.
enum PlatformSpeakerTrackerFactory {
    @MainActor static func forApp(
        bundleID: String?,
        meetingID: UUID,
        archive: MeetingArchive,
        startDate: Date,
        elapsedOffset: TimeInterval
    ) -> PlatformSpeakerTracker {
        if MeetingDetector.isZoomSource(bundleID) {
            return ZoomSpeakerTracker(
                meetingID: meetingID,
                archive: archive,
                startDate: startDate,
                elapsedOffset: elapsedOffset)
        }
        // Meet, Teams, FaceTime, Webex, manual — no AX reader yet.
        // Diarization + the fallback "Others" speaker carry the load.
        return NoopSpeakerTracker()
    }
}

/// A no-op tracker for platforms Nutola can't read by AX yet. Conforms so
/// `RecordingSession` treats every platform uniformly; `speakerAt` returns
/// nil (so diarization owns attribution) and the roster stays empty.
@MainActor
final class NoopSpeakerTracker: PlatformSpeakerTracker {
    var onActiveSpeaker: (@MainActor (String?) -> Void)?
    var onLocalMuteChanged: (@MainActor (Bool) -> Void)?
    nonisolated func speakerAt(_ elapsed: TimeInterval) -> String? { nil }
    nonisolated func currentRoster() -> [String] { [] }
    nonisolated func start() {}
    nonisolated func stop() {}
}
