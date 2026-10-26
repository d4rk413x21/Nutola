import Foundation
import Testing
@testable import Nutola

final class TokenUsageTrackerTests {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tracker: TokenUsageTracker!

    init() {
        suiteName = "nutola-token-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        tracker = TokenUsageTracker(defaults: defaults, key: "token-usage-history")
    }

    deinit {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - record

    @Test func testRecordAddsToToday() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        let days = tracker.last14Days()
        #expect(days.count == 14)
        let today = days.last!
        #expect(today.promptTokens == 100)
        #expect(today.completionTokens == 50)
        #expect(today.totalTokens == 150)
    }

    @Test func testMultipleRecordsSameDayAccumulate() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        tracker.record(promptTokens: 200, completionTokens: 10)
        tracker.record(promptTokens: 1, completionTokens: 0)
        let today = tracker.last14Days().last!
        #expect(today.promptTokens == 301)
        #expect(today.completionTokens == 60)
        #expect(today.totalTokens == 361)
    }

    // MARK: - last14Days

    @Test func testLast14DaysFillsMissingDays() {
        // Only today has data; the window must still be 14 entries.
        tracker.record(promptTokens: 10, completionTokens: 5)
        let days = tracker.last14Days()
        #expect(days.count == 14)
        // The first 13 are zero-filled placeholders.
        for day in days.dropLast() {
            #expect(day.totalTokens == 0)
        }
        // Today holds the only data.
        #expect(days.last!.totalTokens == 15)
    }

    @Test func testLast14DaysIsOldestFirst() {
        tracker.record(promptTokens: 1, completionTokens: 1)
        let days = tracker.last14Days()
        for i in 0..<days.count - 1 {
            #expect(days[i].date < days[i + 1].date, "days must be ascending")
        }
    }

    // MARK: - totalForLast14Days

    @Test func testTotalForLast14Days() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        tracker.record(promptTokens: 200, completionTokens: 100)
        #expect(tracker.totalForLast14Days() == 450)
    }

    @Test func testTotalForLast14DaysEmptyIsZero() {
        #expect(tracker.totalForLast14Days() == 0)
    }

    // MARK: - clear

    @Test func testClearEmptiesHistory() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        #expect(tracker.totalForLast14Days() == 150)
        tracker.clear()
        #expect(tracker.totalForLast14Days() == 0)
        // After clear, last14Days still returns 14 zero-filled rows.
        let days = tracker.last14Days()
        #expect(days.count == 14)
        for day in days {
            #expect(day.totalTokens == 0)
        }
    }

    // MARK: - isolation

    @Test func testIsolationWithTestDefaults() {
        // Writing to the test suite must not leak into standard defaults.
        let standardTracker = TokenUsageTracker()
        let standardBefore = standardTracker.totalForLast14Days()
        tracker.record(promptTokens: 999_999, completionTokens: 999_999)
        #expect(standardTracker.totalForLast14Days() == standardBefore, "test tracker must not write to UserDefaults.standard")
    }

    // MARK: - DailyTokenUsage

    @Test func testDailyTokenUsageTotalAndId() {
        let entry = DailyTokenUsage(date: "2026-07-17", promptTokens: 1234, completionTokens: 567)
        #expect(entry.id == "2026-07-17")
        #expect(entry.totalTokens == 1801)
    }
}
