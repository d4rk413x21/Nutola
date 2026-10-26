import SwiftUI

/// Weekly meeting statistics dashboard: total time, meeting count, longest
/// meeting, busiest day, and a per-day bar chart. Arrows step the week back
/// and forward a week at a time.
struct MeetingInsightsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    @State private var weekAnchor: Date = .now

    private var insights: MeetingInsights {
        MeetingInsightsCalculator.calculate(
            meetings: app.store.meetings,
            forWeekOf: weekAnchor)
    }

    private var weekStart: Date {
        Self.mondayOfWeek(for: weekAnchor)
    }
    private var weekMeetings: [Meeting] {
        let calendar = Calendar.current
        let start = weekStart
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else {
            return app.store.meetings
        }
        return app.store.meetings.filter { $0.createdAt >= start && $0.createdAt < end && $0.state != .prep }
    }

    private var weekRangeLabel: String {
        let calendar = Calendar.current
        let start = weekStart
        guard let end = calendar.date(byAdding: .day, value: 6, to: start) else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if insights.meetingCount == 0 {
                    EmptyStateView(
                        title: "No meetings this week",
                        message: "Recorded meetings will show up in your weekly insights.")
                } else {
                    cards
                    chart
                    talkTimeSection
                    perMeetingSection
                    costSection
                }
            }
            .padding(24)
            .contentColumn()
        }
        .background(Theme.surface(scheme))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Insights")
                    .font(.nutola(22, .bold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
                weekNav
            }
            Text(weekRangeLabel)
                .font(.nutola(13, .medium))
                .foregroundStyle(Theme.secondary(scheme))
        }
    }

    private var weekNav: some View {
        HStack(spacing: 4) {
            Button {
                stepWeek(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous week")
            .accessibilityLabel("Previous week")
            .disabled(false)

            Button {
                weekAnchor = .now
            } label: {
                Text("This week")
                    .font(.nutola(12, .medium))
            }
            .help("Jump to current week")
            .accessibilityLabel("Jump to current week")

            Button {
                stepWeek(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next week")
            .accessibilityLabel("Next week")
            .disabled(isNextDisabled)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(actionColor)
    }

    private var isNextDisabled: Bool {
        Calendar.current.startOfDay(for: weekAnchor)
            >= Calendar.current.startOfDay(for: Date.now)
    }

    private func stepWeek(by weeks: Int) {
        weekAnchor = Calendar.current.date(
            byAdding: .day, value: weeks * 7,
            to: weekAnchor) ?? weekAnchor
    }

    // MARK: - Cards

    private var cards: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            InsightCard(
                title: "Total meeting time",
                value: formatDuration(insights.totalMeetingTime),
                icon: "clock.fill",
                accent: Theme.blueberry(scheme))
            InsightCard(
                title: "Meetings",
                value: "\(insights.meetingCount)",
                icon: "list.bullet.rectangle",
                accent: Theme.mint(scheme))
            InsightCard(
                title: "Longest meeting",
                value: formatDuration(insights.longestMeetingDuration),
                detail: insights.longestMeetingTitle.isEmpty ? nil : insights.longestMeetingTitle,
                icon: "arrow.up.right.diamond.fill",
                accent: Theme.honey(scheme))
            InsightCard(
                title: "Busiest day",
                value: insights.busiestDay.isEmpty ? "—" : insights.busiestDay,
                detail: insights.busiestDayMeetingCount > 0
                    ? "\(insights.busiestDayMeetingCount) meetings"
                    : nil,
                icon: "flame.fill",
                accent: Theme.raspberry)
        }
    }

    // MARK: - Per-day bar chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings per day")
                    .font(.nutola(13, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
                Text(weekRangeLabel)
                    .font(.nutola(12, .medium))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            InsightsBarChart(breakdown: insights.perDayBreakdown, accent: actionColor)
                .frame(height: 96)
        }
        .cardStyle()
    }

    // MARK: - Talk time

    /// Per-speaker talk-time breakdown for the selected week, aggregated by
    /// `TalkTimeDashboardView` across the week's meetings. Embedded as a
    /// card so it matches the per-day chart's framing.
    private var talkTimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TalkTimeDashboardView(meetings: weekMeetings)
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    // MARK: - Per-meeting breakdown

    /// One talk-time card per meeting in the week — the user can see who spoke
    /// in each individual meeting, not just the cross-meeting aggregate. A
    /// single-meeting `TalkTimeDashboardView` already renders a correct
    /// per-speaker ranking, so we just wrap it with the meeting's title/date.
    private var perMeetingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.blueberry(scheme))
                Text("Talk time per meeting")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer(minLength: 0)
            }
            ForEach(transcribedWeekMeetings) { meeting in
                perMeetingCard(meeting)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    /// Week meetings that actually have a transcript to show. Skip recordings
    /// in progress, prep-state stubs, and anything without segments.
    private var transcribedWeekMeetings: [Meeting] {
        weekMeetings.filter { meeting in
            meeting.state == .ready && !app.store.transcript(for: meeting.id).isEmpty
        }
    }

    private func perMeetingCard(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                    .font(.nutola(13, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.nutola(10))
                    .foregroundStyle(Theme.tertiary(scheme))
            }
            Text("\(formatDuration(meeting.duration)) · \(meeting.attendees.count) invited")
                .font(.nutola(10))
                .foregroundStyle(Theme.tertiary(scheme))
            TalkTimeDashboardView(meetings: [meeting])
        }
        .padding(12)
        .background(Theme.chip(scheme), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Meeting cost

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.honey(scheme))
                Text("Estimated meeting cost")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            let totalCost = weekMeetings.reduce(0.0) { sum, meeting in
                let attendees = max(meeting.attendees.count, 1)
                let minutes = Int(meeting.duration / 60)
                return sum + MeetingCostCalculator.calculate(
                    attendeeCount: attendees,
                    durationMinutes: minutes,
                    hourlyRatePerPerson: AppSettings.hourlyRatePerPerson
                ).totalCost
            }
            InsightCard(
                title: "This week",
                value: MeetingCost.format(totalCost),
                icon: "calendar.badge.clock",
                accent: Theme.honey(scheme))
            let perMeeting = insights.meetingCount > 0
                ? totalCost / Double(insights.meetingCount) : 0
            InsightCard(
                title: "Per meeting avg",
                value: MeetingCost.format(perMeeting),
                icon: "divide.circle",
                accent: Theme.blueberry(scheme))
            Text("Based on \(AppSettings.hourlyRatePerPerson, format: .currency(code: "USD")) per person per hour. Change in Settings.")
                .font(.nutola(10))
                .foregroundStyle(Theme.tertiary(scheme))
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    // MARK: - Formatting

    /// "2h 15m" / "45m" / "0m" — matches Nutola's duration formatting style.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded())
        let hours = total / 60
        let minutes = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Snap `date` to the Monday of its week. Uses `Calendar.current` so
    /// the locale's first weekday is respected (most locales start Monday).
    private static func mondayOfWeek(for date: Date) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday - 2 + 7) % 7
        guard let monday = calendar.date(
            byAdding: .day, value: -offset,
            to: calendar.startOfDay(for: date)
        ) else { return calendar.startOfDay(for: date) }
        return monday
    }
}

// MARK: - Insight card

private struct InsightCard: View {
    @Environment(\.colorScheme) private var scheme

    let title: String
    let value: String
    var detail: String? = nil
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.nutola(12, .medium))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.nutola(11, .medium))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            Text(value)
                .font(.nutola(19, .bold))
                .foregroundStyle(Theme.heading(scheme))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.nutola(11))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Per-day bar chart

/// Compact 7-bar chart of meetings per day, sized to sit inside a card.
/// Mirrors the `TokenUsageChart` rhythm: bar height is proportional to that
/// day's meeting count relative to the busiest day in the week; empty days
/// render as zero-height stubs so the 7-bar rhythm is always visible.
private struct InsightsBarChart: View {
    @Environment(\.colorScheme) private var scheme

    let breakdown: [(day: String, count: Int, totalMinutes: Int)]
    let accent: Color

    private var maxCount: Int { breakdown.map(\.count).max() ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(breakdown.enumerated()), id: \.offset) { _, entry in
                    bar(for: entry, availableHeight: height)
                }
            }
        }
    }

    private func bar(
        for entry: (day: String, count: Int, totalMinutes: Int),
        availableHeight: CGFloat
    ) -> some View {
        let ratio = maxCount > 0 ? CGFloat(entry.count) / CGFloat(maxCount) : 0
        let barHeight = max(availableHeight * ratio, entry.count > 0 ? 2 : 0)
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(entry.count > 0 ? 1 : 0.25))
                .frame(height: barHeight)
            Text(entry.day)
                .font(.nutola(9))
                .foregroundStyle(Theme.secondary(scheme))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.day): \(entry.count) meetings")
    }
}
