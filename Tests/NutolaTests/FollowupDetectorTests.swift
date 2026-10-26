import Foundation
import Testing
@testable import Nutola

struct FollowupDetectorTests {
    // A fixed "now" so weekday math is deterministic. 2026-07-15 is a Wednesday.
    // Calendar weekday codes: 1=Sunday … 7=Saturday; Wednesday = 4.
    private let now = makeNow()
    private let calendar = makeCalendar()

    private static func makeNow() -> Date {
        // Use TimeZone.current so the test's date math matches FollowupDetector,
        // which derives its calendar from TimeZone.current. 2026-07-15 is a
        // Wednesday in every timezone (it's a calendar date), so weekday math
        // stays deterministic regardless of the runner's locale.
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = .current
        let comps = DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 0, second: 0)
        return cal.date(from: comps) ?? .now
    }

    private static func makeCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = .current
        return cal
    }

    private func actionItem(_ text: String, owner: String? = nil) -> ActionItem {
        ActionItem(text: text, owner: owner, isChecked: false, lineNumber: 0)
    }

    // MARK: - Weekday phrase

    @Test func testDetectByFriday() {
        // now = Wed 2026-07-15 09:00. "by Friday" → Fri 2026-07-17 (in 2 days).
        let transcript = "Alice: We should send the proposal by Friday to the client."
        let items = [actionItem("Send the proposal")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        let expected = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
        #expect(result[0].dueDate == expected)
        #expect(!(result[0].isOverdue))
        #expect(!(result[0].sourceQuote.isEmpty))
    }

    // MARK: - Relative phrases

    @Test func testDetectTomorrow() {
        let transcript = "Let's follow up with sales tomorrow about the contract."
        let items = [actionItem("Follow up with sales")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        let expected = calendar.date(byAdding: .day, value: 1, to: now)
        #expect(result[0].dueDate == expected)
        #expect(!(result[0].isOverdue))
    }

    @Test func testDetectNextWeek() {
        let transcript = "We'll circle back next week on the roadmap."
        let items = [actionItem("Circle back on the roadmap")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        let expected = calendar.date(byAdding: .day, value: 7, to: now)
        #expect(result[0].dueDate == expected)
        #expect(!(result[0].isOverdue))
    }

    // MARK: - No due date

    @Test func testNoDueDate() {
        let transcript = "Alice will handle the onboarding docs when she has time."
        let items = [actionItem("Handle the onboarding docs")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        #expect(result[0].dueDate == nil)
        #expect(!(result[0].isOverdue))
        #expect(result[0].sourceQuote == "")
    }

    // MARK: - Overdue

    @Test func testIsOverdue() {
        // A due date already in the past relative to `now` is overdue.
        let pastDate = calendar.date(byAdding: .day, value: -3, to: now)!
        let transcript = "We need the budget review done by \(formatDate(pastDate))."
        let items = [actionItem("Budget review")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        #expect(result[0].dueDate != nil)
        #expect(result[0].isOverdue, "past due date should be overdue")
    }

    @Test func testNotOverdue() {
        // A due date in the future is not overdue.
        let transcript = "Let's ship the feature by Friday."
        let items = [actionItem("Ship the feature")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        #expect(result[0].dueDate != nil)
        #expect(!(result[0].isOverdue))
    }

    // MARK: - Owner preservation

    @Test func testOwnerExtracted() {
        let transcript = "Bob will send the invoice by Friday."
        let items = [actionItem("Send the invoice", owner: "Bob")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        #expect(result[0].owner == "Bob")
        #expect(result[0].dueDate != nil)
    }

    // MARK: - Scan window

    @Test func testDuePhraseOutsideWindowIgnored() {
        // A due phrase far from the item text (>200 chars away) shouldn't attach.
        let padding = String(repeating: "x", count: 250)
        let transcript = "Alice: Review the PR. \(padding) Sometime later: by Friday we ship."
        let items = [actionItem("Review the PR")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        // The far-away "by Friday" is outside the window, so no due date attaches.
        #expect(result[0].dueDate == nil)
    }

    @Test func testMultipleItemsResolveIndependently() {
        // The third turn is pushed >200 chars from the due phrases in the first
        // two turns, so its 200-char window contains no due phrase.
        let padding = String(repeating: "We discussed the roadmap and the Q3 priorities at length. ", count: 5)
        let transcript = """
        Alice: Send the proposal by Friday, please.
        Bob: I'll review the contract tomorrow.
        \(padding)Carol: No deadline here, just file the report eventually.
        """
        let items = [
            actionItem("Send the proposal"),
            actionItem("Review the contract"),
            actionItem("File the report")
        ]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 3)
        #expect(result[0].dueDate != nil, "first item has 'by Friday'")
        #expect(result[1].dueDate != nil, "second item has 'tomorrow'")
        #expect(result[2].dueDate == nil, "third item has no due phrase nearby")
    }

    // MARK: - End of week

    @Test func testDetectByEndOfWeek() {
        // now = Wed 2026-07-15. End of week = Sat 2026-07-18 23:59:59.
        let transcript = "Wrap up the migration by end of week."
        let items = [actionItem("Wrap up the migration")]
        let result = FollowupDetector.detect(from: transcript, actionItems: items, now: now)
        #expect(result.count == 1)
        let saturday = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now))!
        let expected = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: saturday)
        #expect(result[0].dueDate == expected)
        #expect(!(result[0].isOverdue))
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d yyyy"
        return formatter.string(from: date)
    }
}
