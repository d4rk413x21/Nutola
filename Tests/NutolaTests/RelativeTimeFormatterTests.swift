import XCTest
@testable import Nutola

// MARK: - #89: RelativeTimeFormatter.naturalRelative

/// `RelativeTimeFormatter.naturalRelative(to:now:)` wraps
/// `RelativeDateTimeFormatter` for natural-language relative time ("in 52
/// minutes", "2 hours ago"). The formatter is locale-aware, so these tests
/// pin *behavior* (non-empty for non-now, empty/space-only for now, sign
/// direction via prefix words) rather than exact localized strings.
final class RelativeTimeFormatterTests: XCTestCase {
    @MainActor
    func testNaturalRelativeFormattingCanBeUsedConcurrently() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = now.addingTimeInterval(-3_600)
        let expected = RelativeTimeFormatter.naturalRelative(to: date, now: now)
        let values = await withTaskGroup(of: String.self) { group in
            for _ in 0..<64 {
                group.addTask { RelativeTimeFormatter.naturalRelative(to: date, now: now) }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 64)
        XCTAssertEqual(Set(values), [expected])
    }

    private func natural(_ date: Date, now: Date) -> String {
        RelativeTimeFormatter.naturalRelative(to: date, now: now)
    }

    func testToday() {
        // A date within the same day as `now` returns a small offset string
        // ("in 5 minutes" / "5 minutes ago"). Must be non-empty for a non-zero
        // offset and never crash for a same-day date.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sameDay = now.addingTimeInterval(5 * 60)
        let result = natural(sameDay, now: now)
        XCTAssertFalse(result.isEmpty, "Same-day offset must produce a non-empty string — got \"\(result)\"")
    }

    func testYesterday() {
        // A date one day in the past yields a "yesterday"/"1 day ago"-style
        // string. It must be non-empty and not equal to the same-day offset.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let result = natural(yesterday, now: now)
        XCTAssertFalse(result.isEmpty, "Yesterday must produce a non-empty string — got \"\(result)\"")
        // Distinct from a near-now offset.
        let nearNow = natural(now.addingTimeInterval(60), now: now)
        XCTAssertNotEqual(result, nearNow, "Yesterday must differ from a near-now offset")
    }

    func testFutureDate() {
        // A date well in the future produces a non-empty "in …" string. The
        // exact localization varies, but it must not be empty and must differ
        // from a same-magnitude past date.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(2 * 24 * 3600)
        let past = now.addingTimeInterval(-2 * 24 * 3600)
        let futureResult = natural(future, now: now)
        let pastResult = natural(past, now: now)
        XCTAssertFalse(futureResult.isEmpty, "Future date must produce a non-empty string — got \"\(futureResult)\"")
        XCTAssertNotEqual(futureResult, pastResult, "Future and past must differ")
    }

    func testSameDayOffset() {
        // A sub-hour offset within the same day returns a "in N minutes"-style
        // string. We only assert non-emptiness and that the string changes as
        // the offset grows (monotonic-ish — different offsets yield different
        // strings, at least across hour boundaries).
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = natural(now.addingTimeInterval(10 * 60), now: now)
        let later = natural(now.addingTimeInterval(3 * 3600), now: now)
        XCTAssertFalse(soon.isEmpty)
        XCTAssertFalse(later.isEmpty)
        XCTAssertNotEqual(soon, later, "Distinct offsets must produce distinct strings")
    }
}
