import XCTest
@testable import Nutola

// MARK: - #87: MenuBarTitleTruncator

/// `MenuBarTitleTruncator.label(for:)` renders the menu-bar slot text for an
/// upcoming event: a (possibly truncated) title followed by a separator +
/// countdown suffix. The title is truncated with a ".." ellipsis when it
/// exceeds the per-slot width budget so the menu-bar item never overflows.
///
/// These tests pin the public `label(for:)` contract:
///   - long titles are truncated and end with the ".." ellipsis
///   - short titles pass through unchanged (suffix still appended)
///   - the title budget never collapses to zero (clamped to a minimum), so a
///     very long countdown can't starve the title to an empty string
@MainActor
final class MenuBarTitleTruncatorTests: XCTestCase {
    private func label(title: String, countdown: String) -> String {
        MenuBarTitleTruncator.label(for: MenuBarUpcomingEvent(title: title, countdown: countdown))
    }

    func testLongTitleTruncated() {
        // A title far wider than the ~148pt menu-bar budget is truncated. The
        // truncated form must end with the ".." ellipsis and retain the suffix.
        let long = String(repeating: "Quarterly Business Review ", count: 10)
        let result = label(title: long, countdown: "in 5m")
        XCTAssertTrue(result.hasSuffix("in 5m"), "Suffix must be preserved — got \(result)")
        XCTAssertTrue(result.contains(".."), "Truncated title must include the ellipsis — got \(result)")
        // Truncated form must be shorter than the untruncated concatenation.
        let untruncated = long + "•in 5m"
        XCTAssertLessThan(result.count, untruncated.count, "Truncation must reduce length — got \(result)")
    }

    func testShortTitleUnchanged() {
        // A short title fits within the budget and passes through verbatim; the
        // suffix is still appended.
        let result = label(title: "Standup", countdown: "in 5m")
        XCTAssertEqual(result, "Standup•in 5m")
    }

    func testZeroWidthBudget() {
        // The title budget is clamped to a minimum (36pt) so a very long
        // countdown can't starve the title to zero width. The result must
        // still contain a non-empty title fragment plus the suffix — never an
        // empty title or a crash. We feed an extremely long countdown to
        // push the computed budget to its floor.
        let hugeCountdown = String(repeating: "in 9999h ", count: 50)
        let result = label(title: "Q4 Review", countdown: hugeCountdown)
        // Suffix is always appended.
        XCTAssertTrue(result.hasSuffix(hugeCountdown), "Suffix must be preserved verbatim — got \(result)")
        // The title portion (everything before the suffix) must be non-empty:
        // the floor budget guarantees at least one character of title survives.
        let title = String(result.dropLast(hugeCountdown.count))
        XCTAssertFalse(title.isEmpty, "Title must not collapse to empty under a huge countdown — got \(title)")
    }
}
