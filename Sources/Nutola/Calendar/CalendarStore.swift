import AppKit
import Combine
import EventKit
import Foundation

@MainActor
final class CalendarStore: ObservableObject {
    static let defaultFetchHorizonDays = 30
    /// Max polls of `resetEventStoreAfterGrant` waiting for the TCC grant to propagate.
    private static let maxResetAttempts = 5
    /// Delay between polls in `resetEventStoreAfterGrant` (200 ms).
    private static let resetRetryDelay: Duration = .milliseconds(200)

    @Published private(set) var agenda: [CalendarAgendaDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var fetchHorizonDays = defaultFetchHorizonDays

    private let eventReader = CalendarEventReader()
    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var ticker: Timer?

    static var isAuthorized: Bool { CalendarAuthorization.isAuthorized }
    static var isDenied: Bool { CalendarAuthorization.isDenied }
    static func requestAccess() async -> Bool { await CalendarAuthorization.requestAccess() }

    init() {
        startObserving()
        startTicker()
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        ticker?.invalidate()
    }

    /// Recreate the EKEventStore after calendar access is granted. The store
    /// created at init (before authorization) won't see events post-grant until
    /// it's reset — that's why the first refresh after granting returns 0 events
    /// even though `authorizationStatus` reads `.fullAccess`. Also handles the
    /// `authorizationStatus` propagation lag: the static status can flap between
    /// `.notDetermined` and `.fullAccess` right after the TCC grant.
    func resetEventStoreAfterGrant() async {
        // Wait for the TCC grant to propagate to `CalendarAuthorization.isAuthorized`.
        // The static status can flap between `.notDetermined` and `.fullAccess` right
        // after the grant, so poll up to `maxResetAttempts` times — but exit as soon
        // as it's ready rather than busy-waiting through the remaining iterations.
        for _ in 0..<Self.maxResetAttempts {
            guard !CalendarAuthorization.isAuthorized else { break }
            try? await Task.sleep(for: Self.resetRetryDelay)
        }
        guard CalendarAuthorization.isAuthorized else { return }
        await eventReader.reset()
        await refreshAgenda()
    }

    func refreshAgenda(
        now: Date = .now,
        horizonDays: Int? = nil
    ) async {
        guard AppSettings.useCalendar, CalendarAuthorization.isAuthorized else {
            NutolaConsoleLog.calendar("refresh skipped — disabled or unauthorized")
            agenda = []
            fetchHorizonDays = Self.defaultFetchHorizonDays
            lastRefresh = now
            return
        }
        let targetHorizon = max(horizonDays ?? fetchHorizonDays, Self.defaultFetchHorizonDays)
        isLoading = true
        defer { isLoading = false }

        let days = await eventReader.agenda(now: now, horizonDays: targetHorizon)

        agenda = days
        fetchHorizonDays = targetHorizon
        lastRefresh = now
        let eventCount = agenda.reduce(0) { $0 + $1.events.count }
        NutolaConsoleLog.calendar("refreshed \(eventCount) events across \(agenda.count) days (horizon=\(targetHorizon)d)")
    }

    func currentEvent(at now: Date = .now, sourceApp: String? = nil) async -> CalendarEventSummary? {
        guard CalendarAuthorization.isAuthorized else { return nil }
        return await eventReader.currentEvent(at: now, sourceApp: sourceApp)
    }

    var nextUpcomingEvent: CalendarEventSummary? {
        CalendarAgendaBuilder.nextUpcoming(in: agenda)
    }

    func upcomingDays(limit: Int = UpcomingMeetings.defaultLimit, now: Date = .now) -> [UpcomingMeetingsDay] {
        UpcomingMeetings.grouped(from: agenda, now: now, limit: limit)
    }

    func timelineDays(
        offsetDays: Int = 0,
        pageDays: Int = UpcomingMeetings.timelinePageDays,
        now: Date = .now
    ) -> [CalendarAgendaDay] {
        UpcomingMeetings.timelineDays(
            from: agenda,
            offsetDays: offsetDays,
            pageDays: pageDays,
            now: now)
    }

    func maxTimelineOffset(pageDays: Int = UpcomingMeetings.timelinePageDays, now: Date = .now) -> Int {
        guard let lastDay = agenda.last?.date else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let lastOffset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: lastDay)).day ?? 0
        return max(0, lastOffset - pageDays + 1)
    }

    func ensureHorizon(forOffsetDays offsetDays: Int, pageDays: Int = UpcomingMeetings.timelinePageDays) async {
        let needed = offsetDays + pageDays
        guard needed > fetchHorizonDays else { return }
        await refreshAgenda(horizonDays: needed + 14)
    }

    func startsInText(for event: CalendarEventSummary, now: Date = .now) -> String? {
        if event.isInProgress { return nil }
        return RelativeTimeFormatter.startsIn(event.start, now: now)
    }

    func endsInText(for event: CalendarEventSummary, now: Date = .now) -> String? {
        guard event.isInProgress else { return nil }
        return RelativeTimeFormatter.endsIn(event.end, now: now)
    }

    func countdownText(for event: CalendarEventSummary, now: Date = .now) -> String? {
        if event.isInProgress {
            return RelativeTimeFormatter.left(until: event.end, now: now)
        }
        return RelativeTimeFormatter.until(event.start, now: now)
    }

    func event(id: String, start: Date? = nil) -> CalendarEventSummary? {
        let matches = agenda.flatMap(\.events).filter { $0.id == id }
        if let start {
            return matches.first { abs($0.start.timeIntervalSince(start)) < 60 }
        }
        return matches.first { !$0.isPast() } ?? matches.first
    }

    private func startObserving() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAgenda() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Debounced: UserDefaults fires on every defaults write (toggling a
            // setting can fire dozens of times), so coalesce into a single refresh
            // 2s later rather than hammering EventKit on each change.
            Task { @MainActor in self?.scheduleRefresh() }
        })
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refreshAgenda()
        }
    }

    /// Recompute countdown labels every minute without re-querying EventKit.
    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
            }
        }
    }
}

/// Owns EventKit objects off the main actor; only value snapshots cross to the UI.
private actor CalendarEventReader {
    private var eventStore = EKEventStore()

    func reset() {
        eventStore = EKEventStore()
    }

    func agenda(now: Date, horizonDays: Int) -> [CalendarAgendaDay] {
        let enabledCalendars = CalendarSources.enabledEKCalendars(in: eventStore)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: start)
        else { return [CalendarAgendaDay]() }
        if enabledCalendars?.isEmpty == true { return [CalendarAgendaDay]() }
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: enabledCalendars)
        let events = eventStore.events(matching: predicate)
        return CalendarAgendaBuilder.buildAgenda(
            from: events, now: now, offsetDays: 0, horizonDays: horizonDays)
    }

    func currentEvent(at now: Date, sourceApp: String?) -> CalendarEventSummary? {
        let enabledCalendars = CalendarSources.enabledEKCalendars(in: eventStore)
        if enabledCalendars?.isEmpty == true { return nil }
        let archive = ArchivedEventStore()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(10 * 60),
            calendars: enabledCalendars)
        let events = eventStore.events(matching: predicate)
            .filter { !archive.isArchived(title: $0.title ?? "", eventID: $0.eventIdentifier ?? "") }
        guard let selected = CalendarEventSelector.select(from: events, at: now, sourceApp: sourceApp)
        else { return nil }
        guard let mapped = CalendarAgendaBuilder.map(selected) else { return nil }
        NutolaConsoleLog.calendar("current event → \"\(mapped.title)\" source=\(sourceApp ?? "none")")
        return mapped
    }
}
