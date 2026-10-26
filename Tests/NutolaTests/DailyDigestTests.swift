import Foundation
import Testing
@testable import Nutola

struct DailyDigestTests {
    private var calendar: Calendar!
    private var now: Date!
    private var yesterdayStart: Date!
    private var generator: DailyDigestGenerator!

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = cal
        now = cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 9))!
        yesterdayStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        generator = DailyDigestGenerator(calendar: cal)
    }

    private func makeMeeting(title: String, createdAt: Date) -> Meeting {
        Meeting(title: title, createdAt: createdAt)
    }

    private func makeEvent(id: String, title: String, hour: Int) -> CalendarEventSummary {
        CalendarEventSummary(
            id: id,
            title: title,
            start: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!,
            end: calendar.date(bySettingHour: hour + 1, minute: 0, second: 0, of: now)!,
            location: nil,
            attendees: [],
            conferenceURL: nil,
            calendarID: nil,
            calendarTitle: nil,
            calendarColor: .gray
        )
    }

    @Test func testGenerateWithMeetings() {
        let m1 = makeMeeting(title: "Standup", createdAt: yesterdayStart.addingTimeInterval(9 * 3600))
        let m2 = makeMeeting(title: "Retro", createdAt: yesterdayStart.addingTimeInterval(14 * 3600))
        let digest = generator.generate(for: now, meetings: [m1, m2], agenda: [])

        #expect(digest.yesterdayMeetings.count == 2)
        #expect(digest.yesterdayMeetings.map(\.title) == ["Standup", "Retro"])
    }

    @Test func testGenerateWithNoMeetings() {
        let digest = generator.generate(for: now, meetings: [], agenda: [])
        #expect(digest.yesterdayMeetings.isEmpty)
        #expect(digest.summary.contains("No meetings yesterday"))
    }

    @Test func testActionItemsExtracted() {
        let m = makeMeeting(title: "Planning", createdAt: yesterdayStart.addingTimeInterval(10 * 3600))
        let summaries: [UUID: String] = [
            m.id: """
            ## Action Items
            - [ ] Send the proposal — Alice
            - [ ] Review the code
            """
        ]
        let digest = generator.generate(for: now, meetings: [m], agenda: [], summaries: summaries)

        #expect(digest.actionItems.count == 2)
        #expect(digest.actionItems[0].text == "Send the proposal")
        #expect(digest.actionItems[0].owner == "Alice")
        #expect(digest.actionItems[1].text == "Review the code")
        #expect(digest.summary.contains("📌 Action Items Due:"))
    }

    @Test func testTodayAgendaIncluded() {
        let e1 = makeEvent(id: "s1", title: "Standup", hour: 10)
        let e2 = makeEvent(id: "s2", title: "Review", hour: 14)
        let digest = generator.generate(for: now, meetings: [], agenda: [e1, e2])

        #expect(digest.summary.contains("📅 Today's Agenda:"))
        #expect(digest.summary.contains("- 10:00 Standup"))
        #expect(digest.summary.contains("- 14:00 Review"))
    }

    @Test func testFormatDigestNonEmpty() {
        let m = makeMeeting(title: "Sync", createdAt: yesterdayStart.addingTimeInterval(11 * 3600))
        let summaries: [UUID: String] = [m.id: "- [ ] Follow up with team"]
        let digest = generator.generate(
            for: now,
            meetings: [m],
            agenda: [makeEvent(id: "x", title: "Lunch", hour: 12)],
            summaries: summaries)
        let formatted = generator.formatDigest(digest)

        #expect(!(formatted.isEmpty))
        #expect(formatted.contains("📋 Yesterday's Digest (1 meetings)"))
        #expect(formatted.contains("Sync — 1 action items"))
    }

    @Test func testOnlyYesterdayMeetings() {
        // Two days ago
        let twoDaysAgoStart = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!
        let old = makeMeeting(title: "Ancient", createdAt: twoDaysAgoStart.addingTimeInterval(9 * 3600))
        // Yesterday
        let yesterday = makeMeeting(title: "Yesterday", createdAt: yesterdayStart.addingTimeInterval(9 * 3600))
        // Today
        let today = makeMeeting(title: "Today", createdAt: now.addingTimeInterval(-1 * 3600))

        let digest = generator.generate(for: now, meetings: [old, yesterday, today], agenda: [])
        #expect(digest.yesterdayMeetings.count == 1)
        #expect(digest.yesterdayMeetings.first?.title == "Yesterday")
        #expect(!(digest.summary.contains("Ancient")))
        #expect(!(digest.summary.contains("Today")))
    }
}
