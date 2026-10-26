import AppKit
import SwiftUI

extension View {
    /// SwiftUI `Menu` on macOS ignores `role: .destructive`; tint the backing `NSMenuItem` red.
    func destructiveMenuItemStyle() -> some View {
        background(DestructiveMenuItemStyle())
    }
}

private struct DestructiveMenuItemStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> DestructiveMenuItemStyleView {
        DestructiveMenuItemStyleView()
    }

    func updateNSView(_ nsView: DestructiveMenuItemStyleView, context: Context) {
        nsView.applyStyle()
    }
}

private final class DestructiveMenuItemStyleView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    func applyStyle() {
        guard let item = enclosingMenuItem else { return }
        let title = item.title
        guard !title.isEmpty else { return }
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
    }
}

struct ConferenceVideoIcon: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.blueberry(scheme))
    }
}

struct ConferenceJoinButton: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var app: AppState
    let label: String
    let url: URL
    var prominent: Bool = false
    /// When non-nil, the button becomes a split button: primary "Join & Record"
    /// starts a recording for this calendar event AND opens the conference URL;
    /// the menu also offers "Join only" (plain open) and "Record only"
    /// (starts recording without joining). nil = the legacy single-action button.
    var calendarEvent: CalendarEventSummary? = nil

    var body: some View {
        Group {
            if let event = calendarEvent {
                splitButton(for: event)
            } else {
                singleButton
            }
        }
    }

    private var singleButton: some View {
        Group {
            if prominent {
                Button {
                    ConferenceJoiner.open(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(label)
                            .font(.nutola(14, .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Theme.blueberry(scheme), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    ConferenceJoiner.open(url)
                } label: {
                    Label(label, systemImage: "video.fill")
                        .font(.nutola(11, .medium))
                }
                .buttonStyle(.bordered)
                .tint(Theme.blueberry(scheme))
                .controlSize(.regular)
            }
        }
    }

    /// Split button: primary "Join & Record" opens the conference and starts a
    /// calendar-linked recording in one tap. The chevron opens a menu with the
    /// plain "Join only" and "Record only" alternatives so the user keeps the
    /// single-tap convenience without losing the original behavior.
    private func splitButton(for event: CalendarEventSummary) -> some View {
        HStack(spacing: 0) {
            Button {
                joinAndRecord(event)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .font(.system(size: prominent ? 14 : 11, weight: .semibold))
                    if prominent {
                        Text("Join & Record")
                            .font(.nutola(14, .semibold))
                    }
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, prominent ? 16 : 10)
                .padding(.vertical, prominent ? 10 : 6)
            }
            .buttonStyle(.plain)
            .background(Theme.blueberry(scheme), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Join meeting and start recording")
            .disabled(app.isRecording)
            .help(app.isRecording
                  ? "A recording is already in progress"
                  : "Open the meeting and start recording")

            Menu {
                Button("Join only") { ConferenceJoiner.open(url) }
                Button {
                    Task { await app.startRecording(calendarEvent: event) }
                } label: {
                    Label("Record only", systemImage: "record.circle")
                }
                .disabled(app.isRecording)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: prominent ? 14 : 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: prominent ? 32 : 24,
                           height: prominent ? 32 : 24)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Meeting join and recording options")
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func joinAndRecord(_ event: CalendarEventSummary) {
        ConferenceJoiner.open(url)
        Task { await app.startRecording(calendarEvent: event) }
    }
}

struct RecordDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nutolaActionColor) private var actionColor
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(actionColor)
            .frame(width: 10, height: 10)
            .opacity(!reduceMotion && pulsing ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = !reduceMotion }
            .onChange(of: reduceMotion) { pulsing = !reduceMotion }
            .accessibilityHidden(true)
    }
}

struct LevelMeter: View {
    var levels: [Float]

    var body: some View {
        MeterBars(levels: levels)
    }
}

/// Bottom-anchored capsules driven by per-segment RMS from the mic tap.
struct MeterBars: View {
    var levels: [Float]
    /// When set, downsamples the full level array (e.g. 12 → 3 for the pill).
    var barCount: Int?

    private let minimumHeight: CGFloat = 4
    private let maximumHeight: CGFloat = 14
    private let containerHeight: CGFloat = 16

    var body: some View {
        let displayLevels = displayedLevels()
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(displayLevels.indices, id: \.self) { index in
                Capsule()
                    .fill(Theme.mint)
                    .frame(
                        width: 4,
                        height: barHeight(for: displayLevels[index])
                    )
            }
        }
        .frame(height: containerHeight, alignment: .bottom)
        .animation(.easeOut(duration: 0.08), value: displayLevels)
    }

    private func displayedLevels() -> [Float] {
        guard let barCount, barCount < levels.count else { return levels }
        return (0..<barCount).map { index in
            let start = index * levels.count / barCount
            let end = (index + 1) * levels.count / barCount
            return levels[start..<end].max() ?? 0
        }
    }

    private func barHeight(for level: Float) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return minimumHeight + ((maximumHeight - minimumHeight) * clamped)
    }
}

struct StateBadge: View {
    @Environment(\.nutolaActionColor) private var actionColor
    let meeting: Meeting
    let stage: String?

    var body: some View {
        switch meeting.state {
        case .prep:
            EmptyView()
        case .recording:
            Label("Recording", systemImage: "record.circle")
                .badgeStyle(actionColor)
        case .processing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(stage ?? "Processing…")
            }
            .badgeStyle(Theme.honey)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .badgeStyle(.orange)
        case .ready:
            EmptyView()
        }
    }
}

/// Flags which engine wrote the summary: Apple Intelligence, Claude, or Codex.
struct ProviderBadge: View {
    let provider: String?

    var body: some View {
        if provider == "claude" {
            badgeLabel("Claude", icon: "sparkles", color: Theme.blueberry)
        } else if provider == "codex" {
            badgeLabel("Codex", icon: "sparkles", color: Theme.raspberry)
        } else if provider == "apple" {
            badgeLabel("Apple Intelligence", icon: "apple.intelligence", color: Theme.mint)
        }
    }

    private func badgeLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
        }
        .badgeStyle(color)
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.nutola(11, .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: 160, alignment: .leading)
            .background(Theme.honey.opacity(0.16), in: Capsule())
            .foregroundStyle(.primary)
    }
}

/// Attendee chips with a compact default — show `limit` items, then "See more".
struct ExpandableChipFlow: View {
    @Environment(\.colorScheme) private var scheme
    let items: [String]
    var limit: Int = 3
    @State private var expanded = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(visibleItems, id: \.self) { Chip(text: $0) }
            if items.count > limit {
                Button(expanded ? "See less" : "See more") {
                    expanded.toggle()
                }
                .font(.nutola(11, .medium))
                .foregroundStyle(Theme.blueberry(scheme))
                .buttonStyle(.plain)
            }
        }
    }

    private var visibleItems: [String] {
        expanded ? items : Array(items.prefix(limit))
    }
}

/// Wraps attendee-style chips onto new rows instead of overflowing the container width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                usedWidth = max(usedWidth, x - spacing)
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + (index < subviews.count - 1 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }

        usedWidth = max(usedWidth, x)
        let width = maxWidth.isFinite ? min(maxWidth, usedWidth) : usedWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.nutola(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    func cardStyle() -> some View {
        modifier(CardBackground())
    }

    /// Full-height calendar color bar on the leading edge of event rows.
    func calendarEventIndicator(_ color: Color, width: CGFloat = 3, spacing: CGFloat = 8) -> some View {
        padding(.leading, width + spacing)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: width)
            }
    }
    /// Applies `transform` to `self` only when `value` is non-nil, so optional
    /// accessibility actions / modifiers can be attached conditionally without
    /// `if`-branching the view tree (which would break ViewBuilder identity).
    @ViewBuilder
    func ifLet<T, R: View>(_ value: T?, transform: (Self, T) -> R) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

struct MeetingNoticeBanner: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    let presentation: MeetingNotice.Presentation
    var primaryActionTitle: String?
    var primaryActionIcon: String?
    var primaryAction: (() -> Void)?

    private var accent: Color {
        presentation.isEmptyTranscript ? Theme.honey(scheme) : Theme.blueberry(scheme)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(scheme == .dark ? 0.16 : 0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.nutola(13, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Text(presentation.message)
                    .font(.nutola(12))
                    .foregroundStyle(Theme.secondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let primaryActionTitle, let primaryAction {
                Button(action: primaryAction) {
                    if let primaryActionIcon {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                            .font(.nutola(12, .semibold))
                    } else {
                        Text(primaryActionTitle)
                            .font(.nutola(12, .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(primaryActionIcon == "mic.fill" ? Theme.mint(scheme) : actionColor)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(accent.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - Meeting history list

enum MeetingListMetadata {
    case attendees(String)
    case duration(String)
    case source(String)

    var icon: String {
        switch self {
        case .attendees: "person.2"
        case .duration: "clock"
        case .source: "app.badge"
        }
    }

    var text: String {
        switch self {
        case .attendees(let text), .duration(let text), .source(let text): text
        }
    }

    static func from(_ meeting: Meeting) -> MeetingListMetadata? {
        if !meeting.attendees.isEmpty {
            let names = meeting.attendees.prefix(2).joined(separator: ", ")
            let extra = meeting.attendees.count - 2
            let text = extra > 0 ? "\(names) & \(extra) others" : names
            return .attendees(text)
        }
        if meeting.duration > 0 {
            return .duration(TemplateRenderer.duration(meeting.duration))
        }
        if let app = meeting.displaySourceApp {
            return .source(app)
        }
        return nil
    }
}

private struct MeetingRowButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var isHovered: Bool
    var isFailed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor(configuration))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func backgroundColor(_ configuration: Configuration) -> Color {
        if isFailed {
            return Color.orange.opacity(scheme == .dark ? 0.12 : 0.08)
        }
        if configuration.isPressed || isHovered {
            return Theme.chip(scheme)
        }
        return Color.clear
    }
}

struct MeetingHistoryRow: View {
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting
    var stage: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    private var metadata: MeetingListMetadata? { MeetingListMetadata.from(meeting) }

    private var displayTitle: String {
        meeting.calendarEventTitle ?? meeting.title
    }

    /// Time shown in the list — see `Meeting.displayTime`.

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(displayTitle)
                            .font(.nutola(14, .medium))
                            .foregroundStyle(Theme.heading(scheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if meeting.calendarEventID != nil {
                            Image(systemName: "calendar")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.blueberry(scheme))
                        }
                    }
                    if let metadata {
                        HStack(spacing: 4) {
                            Image(systemName: metadata.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(metadata.text)
                                .font(.nutola(11))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.secondary(scheme))
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(meeting.displayTime.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.tertiary(scheme))
                    if meeting.state != .ready {
                        StateBadge(meeting: meeting, stage: stage)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .opacity(isHovered ? 0.7 : 0)
                    .frame(width: 10)
            }
        }
        .buttonStyle(MeetingRowButtonStyle(
            isHovered: isHovered,
            isFailed: meeting.state == .failed))
        .onHover { isHovered = $0 }
    }
}

/// The layered-glass motif used in empty states.
struct NutolaStripes: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.cream)
            Rectangle().fill(Theme.honey)
            Rectangle().fill(Theme.raspberry)
            Rectangle().fill(Theme.blueberry)
        }
        .frame(width: 44, height: 56)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 8, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 8))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 8, bottomLeadingRadius: 18,
                bottomTrailingRadius: 18, topTrailingRadius: 8)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct EmptyStateView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor
    let title: String
    let message: String
    var actionTitle: String?
    var actionIcon: String?
    var action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    var tips: [String] = []

    var body: some View {
        VStack(spacing: 14) {
            NutolaStripes()
            Text(title).font(.nutola(17, .semibold))
                .foregroundStyle(Theme.heading(scheme))
            Text(message)
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)

            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tips, id: \.self) { tip in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·")
                                .font(.nutola(12, .bold))
                            Text(tip)
                                .font(.nutola(12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.tertiary(scheme))
                    }
                }
                .frame(maxWidth: 340, alignment: .leading)
                .padding(.top, 2)
            }

            actionRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actionRow: some View {
        let hasPrimary = actionTitle != nil && action != nil
        let hasSecondary = secondaryActionTitle != nil && secondaryAction != nil
        if hasPrimary || hasSecondary {
            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(action: action) {
                        if let actionIcon {
                            Label(actionTitle, systemImage: actionIcon)
                        } else {
                            Text(actionTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
                    .controlSize(.regular)
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .padding(.top, tips.isEmpty ? 0 : 4)
        }
    }
}

/// Minimal markdown display for summaries: headings, bullets, checkboxes,
/// horizontal rules (`---`), inline bold/italic. Anything else renders as a plain paragraph.
struct MarkdownText: View {
    enum Style {
        case card
        case document
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor
    let markdown: String
    var style: Style = .card

    private var bodySize: CGFloat { style == .document ? 13 : 14 }
    private var lineSpacing: CGFloat { style == .document ? 5 : 7 }
    private var bulletColor: Color {
        style == .document ? Theme.tertiary(scheme) : Theme.honey(scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, rawLine in
                line(String(rawLine))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: style == .document ? 4 : 2)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2)))
                .font(style == .document ? .nutola(15, .semibold) : .nutola(22, .bold))
                .foregroundStyle(Theme.heading(scheme))
                .padding(.top, style == .document ? 10 : 4)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3)))
                .font(style == .document ? .nutola(14, .semibold) : .nutola(16, .bold))
                .foregroundStyle(
                    style == .document
                        ? Theme.heading(scheme)
                        : Theme.sectionTitle(scheme, accent: actionColor))
                .padding(.top, style == .document ? 8 : 8)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4)))
                .font(.nutola(bodySize, .semibold))
                .foregroundStyle(Theme.heading(scheme))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: trimmed.hasPrefix("- [x] ") ? "checkmark.square.fill" : "square")
                    .foregroundStyle(bulletColor)
                    .font(.system(size: 12))
                inline(String(trimmed.dropFirst(6)))
                    .font(.nutola(bodySize))
                    .foregroundStyle(Theme.secondary(scheme))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(bulletColor).frame(width: 4, height: 4)
                    .padding(.top, 6)
                inline(String(trimmed.dropFirst(2)))
                    .font(.nutola(bodySize))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            .padding(.leading, style == .document ? 4 : 0)
        } else if Self.isHorizontalRule(trimmed) {
            Divider()
                .opacity(style == .document ? 0.35 : 0.5)
                .padding(.vertical, style == .document ? 6 : 4)
        } else {
            inline(trimmed)
                .font(.nutola(bodySize))
                .foregroundStyle(Theme.secondary(scheme))
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    /// Markdown horizontal rule: `---`, `***`, or `___` (3+ chars, spaces allowed).
    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let char = compact.first else { return false }
        guard char == "-" || char == "*" || char == "_" else { return false }
        return compact.allSatisfy { $0 == char }
    }
}
