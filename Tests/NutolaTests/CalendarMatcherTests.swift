import Foundation
import Testing
@testable import Nutola

extension SharedStateTests {
    struct CalendarMatcherTests {
        @Test func testRelativeTimeWithinWindow() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let start = now.addingTimeInterval(52 * 60)
            #expect(RelativeTimeFormatter.until(start, now: now, within: 3) == "in 52m")
        }

        @Test func testRelativeTimeOutsideWindow() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let start = now.addingTimeInterval(4 * 3600)
            #expect(RelativeTimeFormatter.until(start, now: now, within: 3) == nil)
        }

        @Test func testRelativeTimeHoursAndMinutes() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let start = now.addingTimeInterval(2 * 3600 + 15 * 60)
            #expect(RelativeTimeFormatter.until(start, now: now, within: 3) == "in 2h 15m")
        }

        @Test func testAgendaDayLabels() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 12))!
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let later = calendar.date(byAdding: .day, value: 2, to: today)!

            #expect(CalendarAgendaDay.label(for: today, now: now, calendar: calendar) == "Today")
            #expect(CalendarAgendaDay.label(for: tomorrow, now: now, calendar: calendar) == "Tomorrow")
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d MMMM EEE"
            #expect(CalendarAgendaDay.label(for: later, now: now, calendar: calendar) == f.string(from: later))
        }

        @Test func testMeetingDayGrouperOrdersNewestFirst() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 18))!
            let todayMeeting = Meeting(
                title: "Today",
                createdAt: calendar.date(byAdding: .hour, value: -2, to: now)!)
            let yesterdayMeeting = Meeting(
                title: "Yesterday",
                createdAt: calendar.date(byAdding: .day, value: -1, to: now)!)

            let groups = MeetingDayGrouper.group(
                meetings: [yesterdayMeeting, todayMeeting],
                now: now,
                calendar: calendar)

            #expect(groups.count == 2)
            #expect(groups[0].label == "Today")
            #expect(groups[0].meetings.first?.title == "Today")
            #expect(groups[1].label == "Yesterday")
        }

        @Test func testConferenceURLParserFindsZoomLink() {
            let text = "Join https://zoom.us/j/123456789?pwd=abc for the call"
            let regex = try! NSRegularExpression(pattern: #"https?://[\w.-]*zoom\.us/[^\s<>"]+"#)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let match = regex.firstMatch(in: text, range: range)
            #expect(match != nil)
            #expect(ConferenceURLParser.hostMatchesApp(URL(string: "https://zoom.us/j/123"), sourceApp: "zoom.us"))
            #expect(!(ConferenceURLParser.hostMatchesApp(URL(string: "https://meet.google.com/abc"), sourceApp: "zoom.us")))
        }

        @Test func testUpcomingMeetingsGroupsByDayAndSkipsPast() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 23, minute: 0))!

            let past = CalendarEventSummary(
                id: "past", title: "Past standup", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            let tonight = CalendarEventSummary(
                id: "tonight", title: "test metting", start: now.addingTimeInterval(24 * 60), end: now.addingTimeInterval(39 * 60),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            let tomorrow = CalendarEventSummary(
                id: "tomorrow", title: "All Hands", start: now.addingTimeInterval(12 * 3600), end: now.addingTimeInterval(13 * 3600),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)

            let agenda = [
                CalendarAgendaDay(id: "today", date: calendar.startOfDay(for: now), label: "Today", events: [past, tonight]),
                CalendarAgendaDay(
                    id: "tomorrow",
                    date: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!,
                    label: "Tomorrow",
                    events: [tomorrow]),
            ]

            let grouped = UpcomingMeetings.grouped(from: agenda, now: now, limit: 7, calendar: calendar)
            #expect(grouped.flatMap(\.events).map(\.title) == ["test metting", "All Hands"])
            #expect(grouped.count == 2)
            #expect(grouped[0].label == "Today")
            #expect(grouped[1].label == "Tomorrow")
        }

        @Test func testTimelineDaysCapsAtThreeDaysWithAllEvents() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 10))!
            let today = calendar.startOfDay(for: now)

            func event(_ id: String, day: Date, hour: Int) -> CalendarEventSummary {
                let start = calendar.date(byAdding: .hour, value: hour, to: day)!
                return CalendarEventSummary(
                    id: id, title: id, start: start, end: start.addingTimeInterval(1800),
                    location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            }

            func day(_ offset: Int, events: [CalendarEventSummary]) -> CalendarAgendaDay {
                let date = calendar.date(byAdding: .day, value: offset, to: today)!
                return CalendarAgendaDay(
                    id: "d\(offset)",
                    date: date,
                    label: "Day \(offset)",
                    events: events)
            }

            let heavyDay = (0..<12).map { event("e\($0)", day: today, hour: 11 + $0) }
            let heavyPage = UpcomingMeetings.timelineDays(
                from: [day(0, events: heavyDay)],
                offsetDays: 0,
                pageDays: 3,
                now: now,
                calendar: calendar)
            #expect(heavyPage.count == 1)
            #expect(heavyPage[0].events.count == 12)

            let agenda = (0..<4).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: today)!
                return day(offset, events: [event("d\(offset)", day: date, hour: 14)])
            }
            let page = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 0, pageDays: 3, now: now, calendar: calendar)
            #expect(page.map(\.id) == ["d0", "d1", "d2"])
            #expect(page.flatMap(\.events).map(\.title) == ["d0", "d1", "d2"])
        }

        @Test func testTimelineDaysPagesWindowAndSkipsEmptyDays() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 10))!
            let today = calendar.startOfDay(for: now)
            let day1 = calendar.date(byAdding: .day, value: 1, to: today)!
            let day2 = calendar.date(byAdding: .day, value: 2, to: today)!
            let day4 = calendar.date(byAdding: .day, value: 4, to: today)!

            func event(_ id: String, day: Date, hour: Int) -> CalendarEventSummary {
                let start = calendar.date(byAdding: .hour, value: hour, to: day)!
                return CalendarEventSummary(
                    id: id, title: id, start: start, end: start.addingTimeInterval(1800),
                    location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            }

            let agenda = [
                CalendarAgendaDay(id: "d0", date: today, label: "Today", events: [event("today", day: today, hour: 14)]),
                CalendarAgendaDay(id: "d1", date: day1, label: "Tomorrow", events: [event("tomorrow", day: day1, hour: 12)]),
                CalendarAgendaDay(id: "d2", date: day2, label: "24 July Fri", events: []),
                CalendarAgendaDay(id: "d4", date: day4, label: "27 July Mon", events: [event("monday", day: day4, hour: 9)]),
            ]

            let firstPage = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 0, pageDays: 3, now: now, calendar: calendar)
            #expect(firstPage.map(\.id) == ["d0", "d1"])
            #expect(firstPage.flatMap(\.events).map(\.title) == ["today", "tomorrow"])

            let secondPage = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 3, pageDays: 3, now: now, calendar: calendar)
            #expect(secondPage.map(\.id) == ["d4"])
            #expect(secondPage.flatMap(\.events).map(\.title) == ["monday"])
        }

        @Test func testTimelineShowsEmptyToday() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 18))!
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let past = CalendarEventSummary(
                id: "past", title: "Past", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            let tomorrowEvent = CalendarEventSummary(
                id: "future", title: "Tomorrow", start: tomorrow.addingTimeInterval(3600 * 10), end: tomorrow.addingTimeInterval(3600 * 11),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)

            let agenda = [
                CalendarAgendaDay(id: "d0", date: today, label: "Today", events: [past]),
                CalendarAgendaDay(id: "d1", date: tomorrow, label: "Tomorrow", events: [tomorrowEvent]),
            ]

            let days = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 0, pageDays: 2, now: now, calendar: calendar)
            #expect(days.count == 2)
            #expect(days[0].events.isEmpty)
            #expect(days[1].events.map(\.title) == ["Tomorrow"])
        }

        @Test func testAgendaTimelineFormatterParts() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 12))!
            let parts = AgendaTimelineFormatter.parts(for: date, calendar: calendar)
            #expect(parts.dayNumber == "24")
            #expect(parts.month == "July")
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.calendar = calendar
            weekdayFormatter.locale = .current
            weekdayFormatter.dateFormat = "EEE"
            #expect(parts.weekday == weekdayFormatter.string(from: date))
        }

        @Test func testConferenceDeeplinkZoom() {
            let web = URL(string: "https://zoom.us/j/123456789?pwd=abc")!
            let deeplink = ConferenceJoiner.deeplinkURL(for: web)!
            #expect(deeplink.scheme == "zoommtg")
            #expect(deeplink.host == "zoom.us")
            #expect(deeplink.path == "/join")
            let query = URLComponents(url: deeplink, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.first { $0.name == "confno" }?.value == "123456789")
            #expect(query.first { $0.name == "pwd" }?.value == "abc")
            #expect(query.first { $0.name == "action" }?.value == "join")
        }

        @Test func testConferenceDeeplinkTeams() {
            let web = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc")!
            let deeplink = ConferenceJoiner.deeplinkURL(for: web)!
            #expect(deeplink.scheme == "msteams")
            #expect(deeplink.host == "teams.microsoft.com")
        }

        @Test func testConferenceJoinLabelAndWindow() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let zoom = CalendarEventSummary(
                id: "zoom", title: "test metting",
                start: now.addingTimeInterval(24 * 60), end: now.addingTimeInterval(39 * 60),
                location: nil, attendees: [],
                conferenceURL: URL(string: "https://zoom.us/j/123"),
                calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            #expect(zoom.joinLabel == "Join Zoom")
            #expect(zoom.isWithinCountdownWindow(at: now, hours: 3))
            let far = CalendarEventSummary(
                id: "far", title: "Later",
                start: now.addingTimeInterval(4 * 3600), end: now.addingTimeInterval(5 * 3600),
                location: nil, attendees: [],
                conferenceURL: URL(string: "https://zoom.us/j/456"),
                calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            #expect(!(far.isWithinCountdownWindow(at: now, hours: 3)))

            let meet = CalendarEventSummary(
                id: "meet", title: "Standup",
                start: now.addingTimeInterval(3600), end: now.addingTimeInterval(4500),
                location: nil, attendees: [],
                conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"),
                calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            #expect(meet.joinLabel == "Join Meet")
        }

        @Test func testShouldShowJoinButtonForClusteredMeetings() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let zoomURL = URL(string: "https://zoom.us/j/123")!
            let allHands = CalendarEventSummary(
                id: "all-hands", title: "All Hands",
                start: now.addingTimeInterval(9 * 3600 + 4 * 60),
                end: now.addingTimeInterval(9 * 3600 + 44 * 60),
                location: zoomURL.absoluteString, attendees: [],
                conferenceURL: zoomURL,
                calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            let followUp = CalendarEventSummary(
                id: "follow-up", title: "Follow Up",
                start: now.addingTimeInterval(10 * 3600 + 34 * 60),
                end: now.addingTimeInterval(11 * 3600 + 34 * 60),
                location: zoomURL.absoluteString, attendees: [],
                conferenceURL: zoomURL,
                calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            let peers = [allHands, followUp]

            #expect(CalendarEventSummary.gap(between: allHands, and: followUp) == 50 * 60)
            #expect(allHands.shouldShowJoinButton(among: peers, at: now, hours: 10))
            #expect(followUp.shouldShowJoinButton(among: peers, at: now, hours: 10))

            let far = CalendarEventSummary(
                id: "far", title: "Later",
                start: now.addingTimeInterval(12 * 3600), end: now.addingTimeInterval(13 * 3600),
                location: zoomURL.absoluteString, attendees: [],
                conferenceURL: zoomURL,
                calendarID: nil, calendarTitle: nil, calendarColor: .gray)
            #expect(!(far.shouldShowJoinButton(among: [allHands, far], at: now, hours: 3)))
        }

        @Test func testStartsInFormatter() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let start = now.addingTimeInterval(24 * 60)
            #expect(RelativeTimeFormatter.startsIn(start, now: now) == "in 24m")
        }

        @Test func testEndsInFormatter() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let end = now.addingTimeInterval(14 * 60)
            #expect(RelativeTimeFormatter.endsIn(end, now: now) == "in 14m")
        }

        @Test func testLeftFormatter() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let end = now.addingTimeInterval(13 * 60)
            #expect(RelativeTimeFormatter.left(until: end, now: now) == "13m left")
        }

        @Test func testCalendarSelectionPersistence() {
            AppSettings.resetCalendarSelection()
            #expect(AppSettings.isCalendarEnabled(id: "work"))
            AppSettings.setCalendarEnabled(id: "work", enabled: false)
            #expect(!(AppSettings.isCalendarEnabled(id: "work")))
            AppSettings.setCalendarEnabled(id: "work", enabled: true)
            #expect(AppSettings.isCalendarEnabled(id: "work"))
            AppSettings.resetCalendarSelection()
            #expect(AppSettings.disabledCalendarIDs.isEmpty)
        }

        // MARK: - #81: denied / disabled access returns empty events

        @MainActor
        @Test func testDeniedReturnsEmptyEvents() async {
            // When calendar access is unavailable — denied by the user, or the
            // calendar feature toggled off in Settings — `refreshAgenda` must
            // return an empty agenda rather than querying EventKit. We exercise
            // the deterministic "feature disabled" branch (same `guard … else`
            // early-out as a denied TCC state) so the test is hermetic.
            let store = CalendarStore()
            let key = SettingsKey.useCalendar
            let prior = UserDefaults.standard.object(forKey: key) as? Bool
            UserDefaults.standard.set(false, forKey: key)
            defer {
                if let prior {
                    UserDefaults.standard.set(prior, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            await store.refreshAgenda(now: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(store.agenda.isEmpty, "Disabled calendar must produce an empty agenda")
            #expect(store.nextUpcomingEvent == nil)
        }
    }
}
