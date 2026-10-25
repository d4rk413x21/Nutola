import Foundation

/// Smart Meeting Templates — auto-select a summary template based on what kind of
/// meeting this is. The detected type drives both the `TemplateStore` template name
/// and a short focus hint the AI summarizer folds into its system prompt.
///
/// Detection is cheap and deterministic: it inspects the calendar title, the
/// attendee list (for external email domains), and any transcript keywords already
/// gathered when the meeting starts. The first signal that matches wins, in the
/// order below — title beats attendees beats keywords, so a standup with an
/// external guest is still a standup, not an external call.

enum MeetingType: String, CaseIterable, Sendable {
    case standup
    case interview
    case oneOnOne
    case review
    case presentation
    case brainstorm
    case external
    case generic

    /// Short, human-readable label for chips/badges ("Stand-up", "1-on-1", …).
    var displayName: String {
        switch self {
        case .standup: return "Stand-up"
        case .interview: return "Interview"
        case .oneOnOne: return "1-on-1"
        case .review: return "Review"
        case .presentation: return "Presentation"
        case .brainstorm: return "Brainstorm"
        case .external: return "External"
        case .generic: return "General"
        }
    }

    /// SF Symbol used for the header badge.
    var symbolName: String {
        switch self {
        case .standup: return "person.3.fill"
        case .interview: return "checklist"
        case .oneOnOne: return "person.2.fill"
        case .review: return "chart.bar.doc.horizontal"
        case .presentation: return "play.rectangle.fill"
        case .brainstorm: return "lightbulb.fill"
        case .external: return "globe"
        case .generic: return "rectangle.stack"
        }
    }
}

enum MeetingTemplateResolver {
    /// Domain treated as "internal" — anyone outside it is an external attendee.
    /// Kept lowercase for case-insensitive `contains` checks.
    private static let internalDomain = "doordash.com"

    /// Resolve the meeting type from the calendar title, attendee list, and any
    /// transcript keywords gathered before the summary is generated.
    ///
    /// Title wins over attendees wins over keywords: a "Daily Standup" with an
    /// outside guest is still a standup. The title is matched against substrings
    /// (case-insensitive) so "Victor/Taylor 1:1" and "Weekly Execution Review"
    /// both resolve without needing exact-word boundaries.
    static func resolve(
        title: String,
        attendees: [String],
        transcriptKeywords: [String]
    ) -> MeetingType {
        let lowered = title.lowercased()

        // Title signals, in priority order. The spec lists "sync" under standup
        // and "design" under brainstorm — both are common enough words that we
        // only treat them as meeting-type hints when paired with a meeting-y
        // title, but the spec is explicit, so we honor them directly here.
        if matches(any: ["standup", "stand-up", "stand up", "daily", "sync"], in: lowered) {
            return .standup
        }
        if matches(any: ["interview", "screen"], in: lowered) {
            return .interview
        }
        if matches(any: ["1:1", "1-on-1", "one on one", "one-on-one", "1: 1"], in: lowered) {
            return .oneOnOne
        }
        if matches(any: ["review", "retro", "retrospective"], in: lowered) {
            return .review
        }
        if matches(any: ["presentation", "demo", "demo day"], in: lowered) {
            return .presentation
        }
        if matches(any: ["brainstorm", "design review", "design session", "design sync"], in: lowered) {
            return .brainstorm
        }

        // Attendees: an external (non-DoorDash) email address anywhere in the
        // attendee list makes this an external meeting. Names without an "@"
        // don't trigger external — we only flag when we can actually see a
        // domain that isn't ours.
        if hasExternalAttendee(attendees) {
            return .external
        }

        // Transcript keywords gathered from early speech — only consulted when
        // the title and attendees were inconclusive.
        if let type = typeFromKeywords(transcriptKeywords) {
            return type
        }

        return .generic
    }

    /// Convenience: resolve from a `Meeting` plus any transcript keywords, using
    /// the calendar title (falling back to the meeting title) and the stored
    /// attendees. The header badge uses this so a prep meeting shows its detected
    /// type before any transcript exists.
    static func resolve(for meeting: Meeting, transcriptKeywords: [String] = []) -> MeetingType {
        resolve(
            title: meeting.calendarEventTitle ?? meeting.title,
            attendees: meeting.attendees,
            transcriptKeywords: transcriptKeywords)
    }

    /// The `TemplateStore` template name to use for a given meeting type. Falls
    /// back to the default "Meeting Notes" template for types without a bespoke
    /// built-in, so callers can pass this straight to `TemplateStore.template(named:)`.
    static func templateName(for type: MeetingType) -> String {
        switch type {
        case .oneOnOne: return "1-on-1"
        case .interview: return "Interview"
        case .standup, .review, .presentation, .brainstorm, .external, .generic:
            return "Meeting Notes"
        }
    }

    /// A one-line system-prompt hint for the AI summarizer, tuned to the meeting
    /// type. Empty string for `.generic` so callers can append without producing
    /// a dangling hint.
    static func summaryFocus(for type: MeetingType) -> String {
        switch type {
        case .standup:
            return "Focus on blockers and updates"
        case .interview:
            return "Format as Q&A"
        case .oneOnOne:
            return "Focus on coaching, feedback, and personal context"
        case .review:
            return "Focus on outcomes, metrics, and what to change"
        case .presentation:
            return "Focus on the key message and audience questions"
        case .brainstorm:
            return "Focus on ideas, themes, and trade-offs"
        case .external:
            return "Focus on commitments, owners, and follow-ups"
        case .generic:
            return "Capture the key points, decisions, and action items"
        }
    }

    // MARK: - Matching helpers

    private static func matches(any needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// An attendee counts as external if it looks like an email (contains "@")
    /// and its domain isn't `doordash.com`. Bare names ("Alice") don't reveal
    /// affiliation, so they never trip external.
    private static func hasExternalAttendee(_ attendees: [String]) -> Bool {
        for attendee in attendees {
            guard let at = attendee.lastIndex(of: "@") else { continue }
            let domain = attendee[attendee.index(after: at)...].lowercased()
            guard !domain.isEmpty else { continue }
            if !domain.hasSuffix(internalDomain) {
                return true
            }
        }
        return false
    }

    /// Transcript-keyword fallback. Only a couple of strong signals are mapped
    /// (planning words → brainstorm); anything ambiguous stays generic so we
    /// don't override a real title with noisy word frequencies.
    private static func typeFromKeywords(_ keywords: [String]) -> MeetingType? {
        let lower = Set(keywords.map { $0.lowercased() })
        if lower.contains("roadmap") || lower.contains("planning") || lower.contains("brainstorm") {
            return .brainstorm
        }
        if lower.contains("blocker") || lower.contains("standup") || lower.contains("yesterday") {
            return .standup
        }
        if lower.contains("candidate") || lower.contains("interview") {
            return .interview
        }
        if lower.contains("retro") || lower.contains("retrospective") {
            return .review
        }
        if lower.contains("demo") || lower.contains("presentation") || lower.contains("slides") {
            return .presentation
        }
        return nil
    }
}
