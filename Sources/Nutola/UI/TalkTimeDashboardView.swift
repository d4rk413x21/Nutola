import SwiftUI

/// Cross-meeting talk-time dashboard: a ranked list of who talks the most across
/// all meetings in a period, with a compact bar chart and per-speaker totals.
///
/// Designed to embed as a section inside `MeetingInsightsView` (or any insights
/// surface) and to stand on its own. It is fed by `TalkTimeAggregator`; the
/// transcript/speaker data is resolved from a `MeetingStore` so the view stays
/// free of store-coupling details and easy to preview/test.
struct TalkTimeDashboardView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    /// Meetings to aggregate across. Typically a filtered window (a week), but
    /// any slice works — empty input renders an empty state.
    let meetings: [Meeting]

    @State private var summaries: [SpeakerTalkTimeSummary] = []
    private struct SnapshotKey: Equatable {
        var meetings: [Meeting]
        var transcriptRevision: UInt64
    }

    @State private var renaming: SpeakerTalkTimeSummary?
    @State private var newName: String = ""
    @State private var merging: SpeakerTalkTimeSummary?

    init(meetings: [Meeting]) {
        self.meetings = meetings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                ForEach(summaries) { summary in
                    speakerRow(summary)
                }
            }
        }
        .task(id: SnapshotKey(meetings: meetings, transcriptRevision: app.store.transcriptRevision)) {
            let meetings = meetings
            let archive = app.store.archive
            let result = await Task.detached(priority: .utility) {
                TalkTimeAggregator.aggregate(
                    meetings: meetings,
                    transcripts: meetings.map { ($0.id, archive.transcript(for: $0.id)) },
                    speakers: meetings.map { ($0.id, $0.speakers) })
            }.value
            guard !Task.isCancelled else { return }
            summaries = result
        }
        .sheet(item: $renaming) { summary in
            renameSheet(summary)
        }
        .sheet(item: $merging) { summary in
            mergeSheet(summary)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.mint(scheme))
            Text("Talk time")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
            if !summaries.isEmpty {
                Spacer(minLength: 0)
                Text(grandTotalLabel)
                    .font(.nutola(11, .medium))
                    .foregroundStyle(Theme.tertiary(scheme))
            }
        }
    }

    private var grandTotalLabel: String {
        let total = summaries.reduce(0) { $0 + $1.totalTalkTime }
        return "\(summaries.count) speakers · \(Self.format(hours: total))"
    }

    // MARK: - Rows

    private func speakerRow(_ summary: SpeakerTalkTimeSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summary.name)
                    .font(.nutola(13, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                    .lineLimit(1)
                meetingCountBadge(summary.meetingCount)
                Spacer(minLength: 0)
                Text(Self.format(hours: summary.totalTalkTime))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            if let title = sourceMeetingTitle(summary) {
                Text(title)
                    .font(.nutola(10))
                    .foregroundStyle(Theme.secondary(scheme))
                    .lineLimit(1)
            }
            percentageBar(summary)
            HStack(spacing: 8) {
                Text(String(format: "%.0f%%", summary.percentageOfTotal))
                    .font(.nutola(10, .medium))
                    .foregroundStyle(Theme.tertiary(scheme))
                if summary.meetingCount > 1 {
                    Text("avg \(Self.format(hours: summary.avgTalkTimePerMeeting)) / meeting")
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: summary))
        .contextMenu {
            Button {
                newName = summary.name
                renaming = summary
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            if summaries.count > 1 {
                Button {
                    merging = summary
                } label: {
                    Label("Merge with…", systemImage: "rectangle.dashed.badge.record")
                }
            }
        }
    }

    private func meetingCountBadge(_ count: Int) -> some View {
        Text(count == 1 ? "1 meeting" : "\(count) meetings")
            .font(.nutola(9, .semibold))
            .foregroundStyle(Theme.secondary(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.chip(scheme), in: Capsule())
    }

    private func percentageBar(_ summary: SpeakerTalkTimeSummary) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.chip(scheme))
                    .frame(height: 6)
                Capsule()
                    .fill(barColor(for: summary))
                    .frame(width: max(2, geo.size.width * CGFloat(summary.percentageOfTotal / 100)), height: 6)
            }
        }
        .frame(height: 6)
    }

    private func barColor(for summary: SpeakerTalkTimeSummary) -> Color {
        // Cycle through the Nutola palette so distinct speakers stay visually
        // distinct without depending on a stable per-speaker color map.
        let palette: [Color] = [
            Theme.mint(scheme),
            Theme.blueberry(scheme),
            Theme.honey(scheme),
            Theme.raspberry,
        ]
        let idx = summaries.firstIndex { $0.speakerID == summary.speakerID } ?? 0
        return palette[idx % palette.count]
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No talk time yet")
                .font(.nutola(12, .semibold))
                .foregroundStyle(Theme.tertiary(scheme))
            Text("Transcribe a meeting to see who talks the most.")
                .font(.nutola(11))
                .foregroundStyle(Theme.tertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Aggregation

    // MARK: - Formatting

    /// Formats a duration (in seconds) as compact `Xh Ym`, or just `Ym` under an
    /// hour, or `Xs` under a minute. Keeps the rows narrow.
    static func format(hours seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if m > 0 {
            return s > 0 ? "\(m)m" : "\(m)m"
        }
        return "\(s)s"
    }

    private func sourceMeetingTitle(_ summary: SpeakerTalkTimeSummary) -> String? {
        guard let id = summary.meetingID else { return nil }
        return meetings.first { $0.id == id }?.title
    }

    private func accessibilityLabel(for summary: SpeakerTalkTimeSummary) -> String {
        var parts = [summary.name, Self.format(hours: summary.totalTalkTime)]
        if let title = sourceMeetingTitle(summary) { parts.append("From \(title)") }
        parts.append("\(summary.meetingCount) \(summary.meetingCount == 1 ? "meeting" : "meetings")")
        parts.append(String(format: "%.0f percent of total talk time", summary.percentageOfTotal))
        if summary.meetingCount > 1 {
            parts.append("average \(Self.format(hours: summary.avgTalkTimePerMeeting)) per meeting")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Rename / merge sheets

    /// All distinct calendar attendees across the meetings in scope — offered
    /// as quick-pick chips when renaming. Empty when none of the meetings had
    /// calendar attendees.
    private var calendarAttendeeChips: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for meeting in meetings {
            for raw in meeting.attendees {
                let display = Self.displayName(forAttendee: raw)
                let key = display.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(display)
            }
        }
        // Shortest first so the most specific matches surface early; alphabetical
        // tiebreak keeps the order stable across renders.
        return out.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs < rhs
        }
    }

    /// Turns a raw calendar attendee string into a display name suitable for a
    /// rename chip. Email addresses ("lian.fernandes@doordash.com") become
    /// Title Case names ("Lian Fernandes"); anything that's already a name
    /// ("Lian Fernandes", "Madson Pena") passes through unchanged.
    private static func displayName(forAttendee raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), let local = trimmed.split(separator: "@").first else {
            return trimmed
        }
        // Replace common email separators with spaces, then title-case each word.
        let words = local
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
        return words.joined(separator: " ")
    }

    private func renameSheet(_ summary: SpeakerTalkTimeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(summary.name)")
                .font(.nutola(15, .semibold))
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitRename(summary) }
            if !calendarAttendeeChips.isEmpty {
                Text("Suggested from the calendar invite:")
                    .font(.nutola(11))
                    .foregroundStyle(Theme.secondary(scheme))
                FlowLayout(spacing: 6) {
                    ForEach(calendarAttendeeChips, id: \.self) { attendee in
                        Button { newName = attendee } label: {
                            Text(attendee)
                                .font(.nutola(11, .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.honey(scheme).opacity(0.16), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(summary.meetingID != nil ? "Applies only to this voice in its meeting."
                 : "Applies to every meeting where “\(summary.name)” appears.")
                .font(.nutola(10))
                .foregroundStyle(Theme.tertiary(scheme))
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Rename") { commitRename(summary) }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename(_ summary: SpeakerTalkTimeSummary) {
        let target = newName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        rename(summary, to: target)
        renaming = nil
        newName = ""
    }

    private func rename(_ summary: SpeakerTalkTimeSummary, to target: String) {
        if let meetingID = summary.meetingID, let speakerID = summary.localSpeakerID {
            app.store.renameSpeaker(meetingID: meetingID, speakerID: speakerID, to: target)
        } else {
            app.store.bulkRenameSpeakers(from: summary.name, to: target)
        }
    }

    private func mergeSheet(_ summary: SpeakerTalkTimeSummary) -> some View {
        let others = summaries.filter { $0.speakerID != summary.speakerID && !Speaker.isAnonymousName($0.name) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(summary.name) into…")
                .font(.nutola(15, .semibold))
            Text(summary.meetingID != nil ? "Names only this voice in its meeting."
                 : "Renames \(summary.name) in every meeting to match the speaker you pick.")
                .font(.nutola(11))
                .foregroundStyle(Theme.tertiary(scheme))
            ForEach(others) { other in
                Button {
                    rename(summary, to: other.name)
                    merging = nil
                } label: {
                    HStack {
                        Text(other.name)
                            .font(.nutola(13, .semibold))
                            .foregroundStyle(Theme.heading(scheme))
                        Spacer(minLength: 0)
                        Text(Self.format(hours: other.totalTalkTime))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.secondary(scheme))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Theme.chip(scheme), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel") { merging = nil }
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}
