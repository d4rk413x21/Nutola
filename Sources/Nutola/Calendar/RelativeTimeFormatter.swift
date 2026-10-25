import Foundation
import Synchronization

enum RelativeTimeFormatter {
    /// "in 52m" for any future start — used in the menu "Starts in …" header.
    static func startsIn(_ start: Date, now: Date = .now) -> String? {
        let interval = start.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        return "in " + compact(interval)
    }

    /// "in 52m", "in 2h 15m" — nil when outside the countdown window or already started.
    static func until(
        _ start: Date,
        now: Date = .now,
        within hours: Double = AppSettings.upcomingCountdownHours
    ) -> String? {
        let interval = start.timeIntervalSince(now)
        guard interval > 0, interval <= hours * 3600 else { return nil }
        return "in " + compact(interval)
    }

    /// "in 14m" for any future end — used in the "Ends in …" header.
    static func endsIn(_ end: Date, now: Date = .now) -> String? {
        let interval = end.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        return "in " + compact(interval)
    }

    /// "13m left" — nil when the event has already ended.
    static func left(until end: Date, now: Date = .now) -> String? {
        let interval = end.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        return compact(interval) + " left"
    }

    static func compact(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval.rounded(.up) / 60)
        if totalMinutes < 60 { return "\(max(totalMinutes, 1))m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    /// Localized, natural-language relative time for contexts that aren't
    /// space-constrained (crash history, past meeting timestamps) — backed by
    /// `RelativeDateTimeFormatter` so the result respects the user's locale
    /// ("in 52 minutes", "2 hours ago") rather than the compact menu-bar form.
    /// The compact `compact(_:)/startsIn/until/endsIn/left` APIs above stay
    /// hand-rolled because the menu-bar slot needs the tight "52m"/"2h 15m"
    /// shape their tests pin down, which `RelativeDateTimeFormatter` doesn't
    /// reproduce — those remain the custom edge cases.
    private static let naturalFormatter = Mutex<RelativeDateTimeFormatter>({
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }())

    /// "in 52 min" / "2 hr ago" — localized relative time for a past or future
    /// date. `RelativeDateTimeFormatter` returns "" when `date == now`, so callers
    /// wanting a guaranteed non-empty value should treat "" as "just now".
    static func naturalRelative(to date: Date, now: Date = .now) -> String {
        naturalFormatter.withLock { $0.localizedString(for: date, relativeTo: now) }
    }
}

enum CalendarTimeFormatter {
    private static let range: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func timeRange(start: Date, end: Date) -> String {
        "\(range.string(from: start)) – \(range.string(from: end))"
    }

    static func time(_ date: Date) -> String {
        range.string(from: date)
    }
}
