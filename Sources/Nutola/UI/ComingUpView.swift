import SwiftUI

struct ComingUpView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings

    @State private var agendaOffsetDays = 0
    @StateObject private var archivedStore = ArchivedEventStore()
    private var timelineDays: [CalendarAgendaDay] {
        app.calendar.timelineDays(offsetDays: agendaOffsetDays)
    }

    private var nextEventRowID: String? {
        guard agendaOffsetDays == 0 else { return nil }
        return app.calendar.nextUpcomingEvent?.rowID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                agendaSection
            }
            .padding(24)
            .contentColumn()
        }
        .background(Theme.surface(scheme))
        .task { await app.calendar.refreshAgenda() }
        .onChange(of: app.templates.list().map(\.name)) { _, names in
            app.templateOverrides.pruneUnavailable(available: names)
        }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            agendaHeader

            if !AppSettings.useCalendar {
                emptyCalendarCard("Turn on calendar matching in Settings to see your schedule.")
            } else if CalendarAuthorization.isDenied {
                emptyCalendarCard("Calendar access was denied. Open Settings to allow Nutola to read your schedule.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            } else if !CalendarAuthorization.isAuthorized {
                emptyCalendarCard("Grant calendar access in Settings to see your schedule.") {
                    Task {
                        _ = await CalendarAuthorization.requestAccess()
                        await app.calendar.resetEventStoreAfterGrant()
                    }
                }
            } else if timelineDays.isEmpty {
                emptyCalendarCard(agendaOffsetDays == 0 ? "No upcoming events." : "No events in this range.")
            } else {
                agendaCard
            }
            archivedSection
        }
    }

    @State private var showArchived = false

    private var archivedSection: some View {
        Group {
            if archivedStore.hasAny {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showArchived.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "archivebox.fill")
                                .font(.nutola(13, .medium))
                                .foregroundStyle(Theme.secondary(scheme))
                            Text("Archived")
                                .font(.nutola(13, .semibold))
                                .foregroundStyle(Theme.secondary(scheme))
                            Spacer()
                            Text("\(archivedStore.archivedTitles.count + archivedStore.archivedEvents.count)")
                                .font(.nutola(11))
                                .foregroundStyle(Theme.tertiary(scheme))
                            Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                                .font(.nutola(10))
                                .foregroundStyle(Theme.tertiary(scheme))
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showArchived {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(archivedStore.archivedTitles).sorted(), id: \.self) { title in
                                archivedRow(title: title, isSeries: true)
                            }
                            ForEach(archivedStore.archivedEvents) { evt in
                                archivedRow(title: evt.title, isSeries: false, eventID: evt.id)
                            }
                            Divider()
                                .padding(.top, 4)
                            Button {
                                archivedStore.clearAll()
                                Task { await app.calendar.refreshAgenda() }
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.out.of.square")
                                    Text("Unarchive all")
                                }
                                .font(.nutola(11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.blueberry)
                            .padding(.top, 4)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func archivedRow(title: String, isSeries: Bool, eventID: String? = nil) -> some View {
        HStack {
            Image(systemName: isSeries ? "archivebox.fill" : "archivebox")
                .font(.nutola(11))
                .foregroundStyle(Theme.tertiary(scheme))
            Text(title)
                .font(.nutola(12))
                .foregroundStyle(Theme.secondary(scheme))
                .lineLimit(1)
            Spacer()
            Button {
                if isSeries {
                    archivedStore.unarchiveTitle(title)
                } else if let eventID {
                    archivedStore.unarchiveEvent(id: eventID)
                }
                Task { await app.calendar.refreshAgenda() }
            } label: {
                Image(systemName: "arrow.up.out.of.square")
                    .font(.nutola(11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.blueberry)
            .help("Unarchive")
            .accessibilityLabel("Unarchive")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                if isSeries {
                    archivedStore.unarchiveTitle(title)
                } else if let eventID {
                    archivedStore.unarchiveEvent(id: eventID)
                }
                Task { await app.calendar.refreshAgenda() }
            } label: {
                Label("Unarchive", systemImage: "arrow.up.out.of.square")
            }
        }
    }

    private var agendaHeader: some View {
        HStack(alignment: .center) {
            Text("Coming up")
                .font(.nutola(22, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Spacer()
            if AppSettings.useCalendar, CalendarAuthorization.isAuthorized {
                HStack(spacing: 8) {
                    Button("Today") {
                        Task { await jumpToToday() }
                    }
                    .buttonStyle(.plain)
                    .font(.nutola(13, .medium))
                    .foregroundStyle(agendaOffsetDays == 0 ? Theme.tertiary(scheme) : Theme.blueberry(scheme))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .disabled(agendaOffsetDays == 0)

                    HStack(spacing: 0) {
                        agendaNavButton(
                            systemName: "chevron.left",
                            foreground: agendaOffsetDays == 0 ? Theme.tertiary(scheme) : Theme.secondary(scheme),
                            disabled: agendaOffsetDays == 0
                        ) {
                            Task { await pageBackward() }
                        }

                        agendaNavButton(
                            systemName: "chevron.right",
                            foreground: canPageForward ? Theme.secondary(scheme) : Theme.tertiary(scheme),
                            disabled: !canPageForward
                        ) {
                            Task { await pageForward() }
                        }
                    }
                }
            }
        }
    }

    private var canPageForward: Bool {
        agendaOffsetDays < app.calendar.maxTimelineOffset()
            || agendaOffsetDays + UpcomingMeetings.timelinePageDays < app.calendar.fetchHorizonDays
    }

    private var agendaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if agendaOffsetDays == 0, let first = timelineDays.flatMap(\.events).first {
                if first.isInProgress, let endsIn = app.calendar.endsInText(for: first) {
                    Text("Ends \(endsIn)")
                        .font(.nutola(13, .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                } else if let startsIn = app.calendar.startsInText(for: first) {
                    Text("Starts \(startsIn)")
                        .font(.nutola(13, .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                }
            }

            ForEach(Array(timelineDays.enumerated()), id: \.element.id) { index, day in
                timelineDaySection(day)
                if index < timelineDays.count - 1 {
                    timelineDivider
                }
            }
        }
        .cardStyle()
    }

    private func timelineDaySection(_ day: CalendarAgendaDay) -> some View {
        HStack(alignment: .top, spacing: 16) {
            timelineDateColumn(for: day.date)
            VStack(alignment: .leading, spacing: 8) {
                if day.events.isEmpty {
                    Text("No more events today")
                        .font(.nutola(13))
                        .foregroundStyle(Theme.secondary(scheme))
                        .padding(.vertical, 4)
                } else {
                    ForEach(day.events, id: \.rowID) { event in
                        timelineEventRow(
                            event,
                            peers: day.events,
                            highlighted: event.rowID == nextEventRowID
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timelineDateColumn(for date: Date) -> some View {
        let parts = AgendaTimelineFormatter.parts(for: date)
        return HStack(alignment: .top, spacing: 8) {
            Text(parts.dayNumber)
                .font(.nutola(34, .bold))
                .foregroundStyle(Theme.heading(scheme))
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.month)
                Text(parts.weekday)
            }
            .font(.nutola(12))
            .foregroundStyle(Theme.secondary(scheme))
        }
        .frame(width: 96, alignment: .leading)
    }

    private var timelineDivider: some View {
        Rectangle()
            .fill(Theme.tertiary(scheme).opacity(0.35))
            .frame(height: 1)
            .padding(.leading, 96)
    }

    private func timelineEventRow(
        _ event: CalendarEventSummary,
        peers: [CalendarEventSummary],
        highlighted: Bool
    ) -> some View {
        let showJoin = event.shouldShowJoinButton(among: peers)
        let folderRule = app.folders.folder(forTitle: event.title)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                app.openCalendarEvent(event)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(event.title)
                            .font(.nutola(13, .medium))
                            .foregroundStyle(Theme.heading(scheme))
                            .lineLimit(2)
                        if event.conferenceURL != nil {
                            ConferenceVideoIcon()
                                .alignmentGuide(.firstTextBaseline) { dimensions in
                                    dimensions[.bottom] - 1
                                }
                        }
                    }
                    HStack(spacing: 6) {
                        if let countdown = app.calendar.countdownText(for: event) {
                            Text(countdown)
                                .font(.nutola(11, .semibold))
                                .foregroundStyle(event.isInProgress ? Theme.mint(scheme) : Theme.honey(scheme))
                        }
                        Text(CalendarTimeFormatter.timeRange(start: event.start, end: event.end))
                            .font(.nutola(11))
                            .foregroundStyle(Theme.secondary(scheme))
                    }
                    if let location = event.location {
                        Text(location)
                            .font(.nutola(10))
                            .foregroundStyle(Theme.tertiary(scheme))
                            .lineLimit(1)
                    }
                }
                .calendarEventIndicator(event.calendarColor.swiftUIColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 20)
            timelineEventActions(
                event: event,
                showJoin: showJoin,
                folderRule: folderRule
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.card(scheme).opacity(scheme == .dark ? 0.85 : 0.65))
            }
        }
        .contextMenu {
            Button {
                archivedStore.archiveTitle(event.title)
                Task { await app.calendar.refreshAgenda() }
            } label: {
                Label("Archive series (hide all \"\(event.title)\")", systemImage: "archivebox.fill")
            }
            Button {
                archivedStore.archiveEvent(id: event.id, title: event.title)
                Task { await app.calendar.refreshAgenda() }
            } label: {
                Label("Archive this event only", systemImage: "archivebox")
            }
            Divider()
            templateContextMenu(for: event)
            Divider()
            if archivedStore.hasAny {
                Menu("Archived events") {
                    ForEach(Array(archivedStore.archivedTitles).sorted(), id: \.self) { title in
                        Button {
                            archivedStore.unarchiveTitle(title)
                            Task { await app.calendar.refreshAgenda() }
                        } label: {
                            Label("Unarchive \(title)", systemImage: "arrow.up.out.of.square")
                        }
                    }
                    if !archivedStore.archivedTitles.isEmpty && !archivedStore.archivedEvents.isEmpty {
                        Divider()
                    }
                    ForEach(archivedStore.archivedEvents) { evt in
                        Button {
                            archivedStore.unarchiveEvent(id: evt.id)
                            Task { await app.calendar.refreshAgenda() }
                        } label: {
                            Label("Unarchive \(evt.title)", systemImage: "arrow.up.out.of.square")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        archivedStore.clearAll()
                        Task { await app.calendar.refreshAgenda() }
                    } label: {
                        Label("Clear all archived", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timelineEventActions(
        event: CalendarEventSummary,
        showJoin: Bool,
        folderRule: MeetingFolder?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            FolderPickerMenu(
                currentFolderID: folderRule?.id,
                calendarTitle: event.title,
                meetingID: nil
            ) {
                folderPickerChipLabel(folder: folderRule)
            }
            .buttonStyle(.plain)

            templatePickerChip(for: event)

            if showJoin, let url = event.conferenceURL {
                ConferenceJoinButton(label: event.joinLabel, url: url, calendarEvent: event)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Per-event template assignment chip. Shows the assigned template name (or
    /// a muted "Template" hint on hover), and opens a menu of all templates
    /// plus a "Use default" entry to clear the override. The assignment is
    /// honored by PrepareMeetingUseCase and RecordingServiceImpl, so both the
    /// manual "Record" path and mic-detection auto-start use it.
    @ViewBuilder
    private func templatePickerChip(for event: CalendarEventSummary) -> some View {
        let names = app.templates.list().map(\.name)
        let assigned = app.templateOverrides.overrides[event.id]
        let resolved = (assigned.map { names.contains($0) ? $0 : nil }) ?? nil
        Menu {
            ForEach(names, id: \.self) { name in
                Button {
                    app.templateOverrides.set(eventID: event.id, templateName: name)
                } label: {
                    if name == resolved {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if resolved != nil {
                Divider()
                Button {
                    app.templateOverrides.clear(eventID: event.id)
                } label: {
                    Label("Use default", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            templateChipLabel(name: resolved)
        }
        .buttonStyle(.plain)
        .help(resolved.map { "Template: \($0)" } ?? "Assign a template for this meeting")
    }

    @ViewBuilder
    private func templateChipLabel(name: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(name == nil ? Theme.secondary(scheme) : Theme.mint(scheme))
            if let name {
                Text(name)
                    .font(.nutola(11, .medium))
                    .foregroundStyle(Theme.heading(scheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            (name == nil ? Color.secondary.opacity(0.08) : Theme.mint(scheme).opacity(0.12)),
            in: Capsule()
        )
        .contentShape(Rectangle())
    }
    /// Context-menu version of the template picker — same options, nested
    /// under a "Template" submenu. Kept in sync with `templatePickerChip`.
    @ViewBuilder
    private func templateContextMenu(for event: CalendarEventSummary) -> some View {
        let names = app.templates.list().map(\.name)
        let assigned = app.templateOverrides.overrides[event.id]
        let resolved = (assigned.map { names.contains($0) ? $0 : nil }) ?? nil
        Menu("Template") {
            ForEach(names, id: \.self) { name in
                Button {
                    app.templateOverrides.set(eventID: event.id, templateName: name)
                } label: {
                    if name == resolved {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if resolved != nil {
                Divider()
                Button {
                    app.templateOverrides.clear(eventID: event.id)
                } label: {
                    Label("Use default", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func folderPickerChipLabel(folder: MeetingFolder?) -> some View {
        if let folder {
            FolderIconView(folder: folder, size: 20)
                .contentShape(Rectangle())
        } else {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary(scheme))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
    }

    private func agendaNavButton(
        systemName: String,
        foreground: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .disabled(disabled)
    }

    @ViewBuilder
    private func emptyCalendarCard(_ message: String, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
            if let action {
                Button("Open Settings", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func jumpToToday() async {
        agendaOffsetDays = 0
    }

    private func pageBackward() async {
        agendaOffsetDays = max(0, agendaOffsetDays - UpcomingMeetings.timelinePageDays)
    }

    private func pageForward() async {
        let next = agendaOffsetDays + UpcomingMeetings.timelinePageDays
        await app.calendar.ensureHorizon(forOffsetDays: next)
        agendaOffsetDays = next
    }
}
