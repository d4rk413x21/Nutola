import Foundation

/// One utterance in a meeting transcript. Times are seconds from recording start.
struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct Speaker: Codable, Identifiable, Equatable, Sendable {
    /// Stable key referenced by TranscriptSegment.speakerID ("me", "s1", "s2", …).
    var id: String
    /// Display name, user-editable ("Me", "Speaker 1", "Alice").
    var name: String
    var isMe: Bool = false
}

enum MeetingState: String, Codable, Sendable {
    /// Created from an upcoming calendar event — notes can be prepped before recording.
    case prep
    case recording
    case processing
    case ready
    case failed
}

struct Meeting: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var duration: TimeInterval = 0
    /// App that triggered detection (e.g. "zoom.us"), if auto-detected.
    var sourceApp: String?
    var calendarEventTitle: String?
    var calendarEventID: String?
    var calendarEventStart: Date?
    var calendarEventEnd: Date?
    /// Attendee names from the matched calendar event.
    var attendees: [String] = []
    var speakers: [Speaker] = []
    var state: MeetingState = .recording
    var templateName: String?
    /// Human-readable reason when state == .failed, or a non-fatal warning otherwise.
    var notice: String?
    var publishedURL: String?
    /// Which engine produced the summary: "apple", "claude", or "codex".
    var summaryProvider: String?
    /// User-assigned folder; nil = unfiled (flat Meetings list).
    var folderID: UUID?
    /// Transcript remote speakers were labeled from meeting-client speaker observations.
    var platformSpeakerAttribution: Bool = false

    /// The time to show in the UI for this meeting. Prefer the matched
    /// calendar event's start so a resumed or late-started meeting shows
    /// its scheduled time and lands on the right day in the list, not the
    /// recording-start timestamp. Falls back to `createdAt` for manual
    /// recordings with no calendar link.
    var displayTime: Date {
        calendarEventStart ?? createdAt
    }
}

struct MeetingFolder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var description: String?
    var createdAt: Date
    var sortOrder: Int = 0
    var iconKind: FolderIconKind = .symbol
    /// SF Symbol name when `iconKind == .symbol`, emoji character when `.emoji`.
    var iconValue: String = "folder.fill"
    var iconColorHex: String = "#3FB27F"
}

enum FolderIconKind: String, Codable, Sendable {
    case symbol
    case emoji
}

/// Persisted mapping for auto-filing. Key is normalized calendar title.
struct FolderTitleRule: Codable, Equatable, Sendable {
    var normalizedTitle: String
    var folderID: UUID
    var updatedAt: Date
}

/// Detected conferencing app, derived from a meeting's `sourceApp` bundle id.
/// Centralizes the bundle-id → display-name mapping so the same rules apply to
/// list subtitles, detail tips, and any future surface.
enum ConferenceSource: Sendable {
    case granola
    case zoom
    case teams
    case googleMeet
    case webex
    case slack
    case facetime
    case other(String)

    /// Maps a `sourceApp` bundle id (case-insensitive substring match) to a
    /// source. Returns nil when `sourceApp` is empty/nil. Unrecognized ids fall
    /// back to `.other(sourceApp)`.
    init?(sourceApp: String?) {
        guard let raw = sourceApp?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("granola") { self = .granola }
        else if raw.contains("zoom") { self = .zoom }
        else if raw.contains("teams") { self = .teams }
        else if raw.contains("meet") || raw.contains("google") { self = .googleMeet }
        else if raw.contains("webex") { self = .webex }
        else if raw.contains("slack") { self = .slack }
        else if raw.contains("facetime") { self = .facetime }
        else { self = .other(sourceApp!) }
    }

    /// Human-readable app name for list subtitles and tips.
    var displayName: String {
        switch self {
        case .granola: return "Granola"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .googleMeet: return "Google Meet"
        case .webex: return "Webex"
        case .slack: return "Slack"
        case .facetime: return "FaceTime"
        case .other(let raw): return raw
        }
    }
}
extension Meeting {
    static func placeholderTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE h:mm a"
        return "Meeting · \(f.string(from: date))"
    }

    /// Whether the user can pick up recording on this meeting again — after a failed
    /// capture, an empty finish, or to append more audio to an existing meeting.
    func canStartFromPrep(isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        return state == .prep
    }

    func canContinueRecording(isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        // .recording/.prep are genuinely live or staged starts — never auto-resume.
        // .processing is an orphan being finalized by finalizeOrphans (no live
        // RecordingSession holds it); treat it as resumable so a detection-driven
        // start on the same launch rejoins the same calendar meeting instead of
        // creating a duplicate. The resume path cancels the orphan's process task.
        guard state != .recording, state != .prep else { return false }
        return state == .failed || state == .ready || state == .processing
    }

    /// Whether auto-detection should append to this meeting instead of creating a new one.
    func canResumeRecording(isRecording: Bool) -> Bool {
        canStartFromPrep(isRecording: isRecording) || canContinueRecording(isRecording: isRecording)
    }

    /// Human-readable source for list subtitles (bundle IDs → app names).
    /// Backed by `ConferenceSource` so the bundle-id → name mapping lives in one place.
    var displaySourceApp: String? {
        ConferenceSource(sourceApp: sourceApp)?.displayName
    }
}
