import SwiftUI
import AppKit

/// The Daily Digest page — a briefing of today's or yesterday's meetings,
/// plus an Activity Tracker that turns the digest's action items into a
/// persistent, filterable todo list.
///
/// The digest is generated on demand (Start Digest); the tracker is always
/// present, auto-synced from meeting summaries, and manually editable. The
/// digest feeds the tracker: clicking "Track" on a digest action item adds
/// it to the persistent list.
struct DailyDigestView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    // Digest state
    @State private var digest: DailyDigest?
    @State private var cachedDigest: DailyDigest?
    @State private var isGenerating = false
    @State private var digestMode: DigestMode = .today
    /// Locally checked digest items (keyed by item id).
    @State private var digestChecked: Set<UUID> = []
    // Filter for the digest's action items: nil = "Mine" (current user).
    @State private var digestItemFilter: String? = nil
    @State private var digestShowAllOwners = false
    // Tracker state
    @State private var showAddSheet = false
    @State private var editingTask: TrackedTask?
    @State private var showRenameSheet = false
    @State private var showMergeSheet = false
    @State private var renameFrom = ""
    @State private var mergeFrom = ""
    @State private var filterOwner: String? // nil = "mine"
    @State private var filterTag: String?
    @State private var showCompleted = false
    @State private var showPrepSection = true

    private let generator = DailyDigestGenerator()
    private var tracker: TaskTrackerStore { app.tracker }

    enum DigestMode: String, CaseIterable, Identifiable {
        case today = "Today so far"
        case yesterday = "Yesterday"
        var id: String { rawValue }
    }

    // MARK: - Filtered tasks

    private var filteredTasks: [TrackedTask] {
        tracker.sortedTasks.filter { task in
            if !showCompleted && task.isChecked { return false }
            if let filterOwner, task.owner != filterOwner { return false }
            if let filterTag, !task.tags.contains(filterTag) { return false }
            if filterOwner == nil && !task.isMine { return false }
            return true
        }
    }

    private var prepTasks: [TrackedTask] {
        tracker.sortedTasks.filter { $0.calendarEventID != nil && !$0.isChecked }
    }

    private var upcomingForPrep: [CalendarEventSummary] {
        let agenda = app.calendar.upcomingDays(limit: 5).flatMap(\.events)
        let existingIDs = Set(tracker.tasks.compactMap { $0.calendarEventID })
        return agenda.filter { event in
            event.start >= Date() && !existingIDs.contains(event.id)
        }
    }

    private var unknownOwners: [String] {
        tracker.owners.filter { owner in
            owner.lowercased().hasPrefix("speaker ") || owner.lowercased().contains("unknown")
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modePicker

                // Action items list — uses cachedDigest so it persists.
                if let cached = cachedDigest, !cached.actionItems.isEmpty {
                    digestActionItemsCard(cached)
                }

                trackerSection

                // Digest briefing — meetings + agenda.
                if let digest {
                    digestContent(digest)
                } else {
                    emptyState
                }
            }
            .padding(24)
            .contentColumn()
        }
        .background(Theme.surface(scheme))
        .onAppear {
            if cachedDigest == nil { generateDigest() }
        }
        .sheet(isPresented: $showAddSheet) {
            TaskEditSheet(task: nil) { newTask in
                tracker.add(
                    text: newTask.text,
                    detail: newTask.detail,
                    owner: newTask.owner,
                    isMine: newTask.isMine,
                    priority: newTask.priority,
                    tags: newTask.tags,
                    dueDate: newTask.dueDate)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingTask != nil },
            set: { if !$0 { editingTask = nil } })
        ) {
            if let task = editingTask {
                TaskEditSheet(task: task) { updated in
                    tracker.update(updated)
                    editingTask = nil
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameOwnerSheet(from: renameFrom) { newName in
                tracker.renameOwner(from: renameFrom, to: newName)
                tracker.addAlias(from: renameFrom, to: newName)
                showRenameSheet = false
            }
        }
        .sheet(isPresented: $showMergeSheet) {
            MergeOwnerSheet(
                from: mergeFrom,
                existingOwners: tracker.owners
            ) { target in
                tracker.addAlias(from: mergeFrom, to: target)
                showMergeSheet = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily Digest")
                .font(.nutola(22, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Text("Get a quick briefing of your meetings and action items.")
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
        }
    }

    // MARK: - Mode picker + Start button

    private var modePicker: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $digestMode) {
                ForEach(DigestMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Spacer()

            Button {
                generateDigest()
            } label: {
                Label(isGenerating ? "Generating…" : "Start Digest",
                      systemImage: isGenerating ? "arrow.clockwise" : "play.fill")
                    .font(.nutola(13, .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.mint(scheme))
            .clipShape(Capsule())
            .disabled(isGenerating)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.tertiary(scheme))
            Text("No digest generated yet")
                .font(.nutola(14, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
            Text("Click **Start Digest** to get a summary of your "
                + "\(digestMode == .today ? "day so far" : "yesterday").")
                .font(.nutola(12))
                .foregroundStyle(Theme.tertiary(scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Digest content

    private func digestContent(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if digest.yesterdayMeetings.isEmpty {
                noMeetingsCard
            } else {
                meetingsCard(digest)
            }


            if !digest.todayAgenda.isEmpty {
                agendaCard(digest)
            }

            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        generator.formatDigest(digest),
                        forType: .string)
                } label: {
                    Label("Copy Digest", systemImage: "doc.on.doc")
                        .font(.nutola(12, .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var noMeetingsCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary(scheme))
            Text("No meetings \(digestMode == .today ? "today" : "yesterday")")
                .font(.nutola(13, .semibold))
                .foregroundStyle(Theme.secondary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func meetingsCard(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.blueberry(scheme))
                Text("\(digest.yesterdayMeetings.count) meetings \(digestMode == .today ? "today" : "yesterday")")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            ForEach(digest.yesterdayMeetings, id: \.id) { meeting in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.mint(scheme))
                    Text(meeting.title)
                        .font(.nutola(12, .medium))
                        .foregroundStyle(Theme.heading(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(RelativeTimeFormatter.naturalRelative(to: meeting.createdAt))
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Digest action items (with "Track" buttons)

    private func digestActionItemsCard(_ digest: DailyDigest) -> some View {
        let filtered = digestFilteredItems(digest)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checklist")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.honey(scheme))
                Text("\(filtered.count) of \(digest.actionItems.count) action items")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            // Owner filter bar
            digestItemFilterBar(digest)
            // Filtered items
            ForEach(filtered, id: \.id) { item in
                digestActionItemRow(item, digest: digest)
            }
            if filtered.isEmpty {
                Text("No items match this filter")
                    .font(.nutola(11))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Distinct resolved owners from the digest's action items, sorted.
    private func digestItemOwners(_ digest: DailyDigest) -> [String] {
        let raw = Set(digest.actionItems.compactMap { $0.owner })
        let resolved = Set(raw.map { tracker.resolveOwner($0) })
        return resolved.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// The action items after applying the owner filter.
    /// Default (nil + showAll=false) filters to the current user.
    private func digestFilteredItems(_ digest: DailyDigest) -> [ActionItem] {
        if digestShowAllOwners { return digest.actionItems }
        let target = digestItemFilter ?? AppSettings.currentUserName
        return digest.actionItems.filter { item in
            guard let owner = item.owner else { return false }
            return tracker.resolveOwner(owner).lowercased()
                .contains(target.lowercased())
        }
    }

    private func digestItemFilterBar(_ digest: DailyDigest) -> some View {
        let owners = digestItemOwners(digest)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary(scheme))
                    .padding(.top, 1)

                digestFilterPill(
                    label: "Mine",
                    isActive: !digestShowAllOwners
                        && digestItemFilter == nil,
                    action: {
                        digestShowAllOwners = false
                        digestItemFilter = nil
                    }
                )

                ForEach(owners, id: \.self) { owner in
                    DigestOwnerPill(
                        owner: owner,
                        isActive: digestIsActive(owner: owner),
                        action: { digestSelectOwner(owner) },
                        onMerge: { mergeOwnerFromDigest(owner) },
                        onRename: { renameOwnerFromDigest(owner) }
                    )
                }

                digestFilterPill(
                    label: "All",
                    isActive: digestShowAllOwners,
                    action: {
                        digestShowAllOwners = true
                        digestItemFilter = nil
                    }
                )
            }
        }
        .padding(.bottom, 2)
    }

    private func mergeOwnerFromDigest(_ owner: String) {
        showMergeSheet = true
        mergeFrom = owner
    }

    private func renameOwnerFromDigest(_ owner: String) {
        showRenameSheet = true
        renameFrom = owner
    }

    private func digestIsActive(owner: String) -> Bool {
        if digestShowAllOwners { return false }
        if digestItemFilter == nil {
            return owner.lowercased()
                .contains(AppSettings.currentUserName.lowercased())
        }
        return digestItemFilter == owner
    }

    private func digestSelectOwner(_ owner: String) {
        digestShowAllOwners = false
        let isCurrentUser = owner.lowercased()
            .contains(AppSettings.currentUserName.lowercased())
        digestItemFilter = isCurrentUser ? nil : owner
    }

    private func digestFilterPill(
        label: String, isActive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.nutola(10, .semibold))
                .foregroundStyle(isActive ? .white : Theme.secondary(scheme))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isActive ? actionColor : Theme.chip(scheme),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func digestActionItemRow(
        _ item: ActionItem, digest: DailyDigest
    ) -> some View {
        let resolvedOwner = item.owner.map { tracker.resolveOwner($0) }
        let isMine = resolvedOwner?.lowercased()
            .contains(AppSettings.currentUserName.lowercased()) ?? false
        let isLocallyChecked = digestChecked.contains(item.id)
        return HStack(spacing: 8) {
            Button {
                if isLocallyChecked {
                    digestChecked.remove(item.id)
                } else {
                    digestChecked.insert(item.id)
                }
            } label: {
                Image(systemName: isLocallyChecked
                    ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isLocallyChecked
                        ? Theme.mint(scheme) : Theme.tertiary(scheme))
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.nutola(12))
                .foregroundStyle(isLocallyChecked
                    ? Theme.secondary(scheme) : Theme.heading(scheme))
                .strikethrough(isLocallyChecked)
                .lineLimit(2)
            // Only show the owner badge when "All" is active or the owner
            // differs from the current filter — avoids repeating the same
            // pill on every row when filtering by one owner.
            if let owner = resolvedOwner, shouldShowOwnerBadge(owner: owner) {
                Text(owner)
                    .font(.nutola(10, .semibold))
                    .foregroundStyle(
                        isMine ? actionColor : Theme.blueberry(scheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (isMine ? actionColor : Theme.blueberry(scheme))
                            .opacity(0.12),
                        in: Capsule()
                    )
            }
            Spacer(minLength: 0)
            Button {
                trackDigestItem(item, from: digest)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(actionColor)
            }
            .buttonStyle(.plain)
            .help("Add to Activity Tracker")
            .accessibilityLabel("Add to Activity Tracker")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Show the owner badge only when viewing "All" or when the owner
    /// differs from the active filter target.
    private func shouldShowOwnerBadge(owner: String) -> Bool {
        if digestShowAllOwners { return true }
        let target = digestItemFilter ?? AppSettings.currentUserName
        return !owner.lowercased().contains(target.lowercased())
    }

    private func trackDigestItem(_ item: ActionItem, from digest: DailyDigest) {
        // Find which meeting this item came from.
        let meetingIndex = digest.actionItems.firstIndex { $0.id == item.id }
        let meeting = meetingIndex.flatMap { index in
            index < digest.yesterdayMeetings.count ? digest.yesterdayMeetings[index] : nil
        }
        let source = meeting.map { TaskSource(meetingID: $0.id, meetingTitle: $0.title) }
        let owner = item.owner ?? AppSettings.currentUserName
        let isMine = owner.lowercased() == AppSettings.currentUserName.lowercased()
        let priority = TaskPriorityHeuristics.assess(for: item.text, owner: item.owner)

        // Don't duplicate if already tracked.
        let alreadyTracked = tracker.tasks.contains { task in
            task.text.lowercased().trimmingCharacters(in: .whitespaces)
                == item.text.lowercased().trimmingCharacters(in: .whitespaces)
                && task.source?.meetingID == (meeting?.id ?? UUID())
        }
        guard !alreadyTracked else { return }

        tracker.add(
            text: item.text,
            detail: nil,
            owner: owner,
            isMine: isMine,
            priority: priority,
            tags: [],
            source: source)
    }

    private func agendaCard(_ digest: DailyDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.mint(scheme))
                Text(digestMode == .today ? "Upcoming" : "Today's Agenda")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
            }
            ForEach(digest.todayAgenda.filter { $0.start >= Date() }, id: \.rowID) { event in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(event.calendarColor.swiftUIColor)
                    Text(event.title)
                        .font(.nutola(12, .medium))
                        .foregroundStyle(Theme.heading(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(CalendarTimeFormatter.timeRange(start: event.start, end: event.end))
                        .font(.nutola(10))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Tracker section

    private var trackerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            trackerHeader
            insightsCard
            if !prepTasks.isEmpty || !upcomingForPrep.isEmpty {
                prepSection
            }
            filterBar
            taskList
        }
    }

    private var trackerHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Activity Tracker")
                .font(.nutola(16, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Label("Add Task", systemImage: "plus")
                    .font(.nutola(12, .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(actionColor)
            .clipShape(Capsule())
        }
    }

    private var insightsCard: some View {
        let insights = tracker.dailyInsights(for: 7)
        let totalOpen = tracker.openCount
        let totalDone = tracker.completedCount
        let rate = tracker.completionRate

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.blueberry(scheme))
                Text("This Week")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
                Text("\(totalDone) done \u{00B7} \(totalOpen) open \u{00B7} \(Int(rate * 100))%")
                    .font(.nutola(11, .medium))
                    .foregroundStyle(Theme.secondary(scheme))
            }
            TaskInsightsChart(insights: insights, accent: actionColor)
                .frame(height: 80)
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Mine") { filterOwner = nil }
                ForEach(tracker.owners, id: \.self) { owner in
                    Button(owner) { filterOwner = owner }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                    Text(filterOwner ?? "Mine")
                        .font(.nutola(12, .medium))
                }
                .foregroundStyle(Theme.heading(scheme))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if !tracker.allTags.isEmpty {
                Menu {
                    Button("All tags") { filterTag = nil }
                    ForEach(tracker.allTags, id: \.self) { tag in
                        Button(tag) { filterTag = tag }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 10))
                        Text(filterTag ?? "All tags")
                            .font(.nutola(12, .medium))
                    }
                    .foregroundStyle(Theme.heading(scheme))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Toggle(isOn: $showCompleted) {
                Text("Show completed")
                    .font(.nutola(11, .medium))
            }
            .toggleStyle(.checkbox)
            .font(.nutola(11))

            Spacer()

            if !unknownOwners.isEmpty {
                Menu {
                    ForEach(unknownOwners, id: \.self) { owner in
                        Button("Rename \(owner)\u{2026}") {
                            renameFrom = owner
                            showRenameSheet = true
                        }
                    }
                } label: {
                    Label("Fix names", systemImage: "person.text.rectangle")
                        .font(.nutola(11, .medium))
                }
                .menuStyle(.borderlessButton)
            }

            if tracker.completedCount > 0 {
                Button {
                    tracker.clearCompleted()
                } label: {
                    Text("Clear done")
                        .font(.nutola(11, .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var taskList: some View {
        Group {
            if filteredTasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Theme.tertiary(scheme))
                    Text(tracker.tasks.isEmpty ? "No tasks yet" : "Nothing matches your filters")
                        .font(.nutola(14, .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                    Text(tracker.tasks.isEmpty
                        ? "Tasks from your meeting summaries will appear here automatically. You can also add one manually."
                        : "Try changing the owner filter or showing completed tasks.")
                        .font(.nutola(12))
                        .foregroundStyle(Theme.tertiary(scheme))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredTasks) { task in
                        TaskRow(task: task, onTap: {
                            tracker.toggle(id: task.id)
                        }, onEdit: {
                            editingTask = task
                        }, onDelete: {
                            tracker.delete(id: task.id)
                        }, onClaim: {
                            tracker.claimOwnership(id: task.id)
                        })
                    }
                }
            }
        }
    }

    private var prepSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.plus")
                    .font(.nutola(13, .medium))
                    .foregroundStyle(Theme.honey(scheme))
                Text("Prep for upcoming meetings")
                    .font(.nutola(14, .semibold))
                    .foregroundStyle(Theme.heading(scheme))
                Spacer()
                Button {
                    withAnimation { showPrepSection.toggle() }
                } label: {
                    Image(systemName: showPrepSection
                        ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPrepSection ? "Collapse meeting preparation" : "Expand meeting preparation")
            }
            if showPrepSection {
                VStack(alignment: .leading, spacing: 8) {
                    // Existing prep tasks
                    if !prepTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(prepTasks) { task in
                                TaskRow(task: task, onTap: {
                                    tracker.toggle(id: task.id)
                                }, onEdit: {
                                    editingTask = task
                                }, onDelete: {
                                    tracker.delete(id: task.id)
                                }, onClaim: {
                                    tracker.claimOwnership(id: task.id)
                                })
                            }
                        }
                    }
                    // Add-prep buttons for upcoming events without one yet
                    if !upcomingForPrep.isEmpty {
                        if !prepTasks.isEmpty {
                            Divider().padding(.vertical, 2)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Quick add")
                                .font(.nutola(9, .semibold))
                                .foregroundStyle(Theme.tertiary(scheme))
                                .textCase(.uppercase)
                            ForEach(upcomingForPrep, id: \.rowID) { event in
                                Button {
                                    tracker.add(
                                        text: "Prep for \(event.title)",
                                        detail: nil,
                                        isMine: true,
                                        priority: .normal,
                                        tags: ["prep"],
                                        source: nil,
                                        calendarEventID: event.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 9))
                                            .foregroundStyle(actionColor)
                                        Text(event.title)
                                            .font(.nutola(11, .medium))
                                            .foregroundStyle(
                                                Theme.secondary(scheme))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(event.start,
                                            format: .dateTime
                                                .month().day().hour().minute())
                                            .font(.nutola(9))
                                            .foregroundStyle(
                                                Theme.tertiary(scheme))
                                    }
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Generation

    private func generateDigest() {
        isGenerating = true
        let meetings = app.store.meetings
        let agenda = app.calendar.upcomingDays(limit: 10).flatMap(\.events)
        let summaries = Dictionary(
            uniqueKeysWithValues: meetings.map { ($0.id, app.store.summary(for: $0.id)) })

        let result: DailyDigest
        switch digestMode {
        case .today:
            result = generator.generateToday(
                for: Date(), meetings: meetings, agenda: agenda, summaries: summaries)
        case .yesterday:
            result = generator.generate(
                for: Date(), meetings: meetings, agenda: agenda, summaries: summaries)
        }
        digest = result
        cachedDigest = result
        isGenerating = false
    }
}

// MARK: - Digest owner filter pill

private struct DigestOwnerPill: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    let owner: String
    let isActive: Bool
    let action: () -> Void
    var onMerge: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            Text(owner)
                .font(.nutola(10, .semibold))
                .foregroundStyle(isActive ? .white : Theme.secondary(scheme))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isActive ? actionColor : Theme.chip(scheme),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Filter") { action() }
            if let onRename {
                Button("Rename\u{2026}") { onRename() }
            }
            if let onMerge {
                Button("Merge with\u{2026}") { onMerge() }
            }
        }
    }
}

// MARK: - Task row

private struct TaskRow: View {
    let task: TrackedTask
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClaim: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onTap) {
                Image(systemName: task.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.isChecked ? Theme.mint(scheme) : Theme.tertiary(scheme))
            }
            .buttonStyle(.plain)
            .help(task.isChecked ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.text)
                    .font(.nutola(13, .medium))
                    .foregroundStyle(task.isChecked ? Theme.secondary(scheme) : Theme.heading(scheme))
                    .strikethrough(task.isChecked)
                    .lineLimit(3)

                if let detail = task.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.nutola(11))
                        .foregroundStyle(Theme.tertiary(scheme))
                        .lineLimit(2)
                }

                if let source = task.source {
                    Text("From \(source.meetingTitle)")
                        .font(.nutola(9))
                        .foregroundStyle(Theme.tertiary(scheme).opacity(0.7))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: task.priority.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(task.priority.color.opacity(0.8))
                .help(task.priority.label)

            if let owner = task.owner {
                Text(owner)
                    .font(.nutola(9, .semibold))
                    .foregroundStyle(task.isMine ? actionColor : Theme.blueberry(scheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (task.isMine ? actionColor : Theme.blueberry(scheme)).opacity(0.12),
                        in: Capsule()
                    )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit\u{2026}") { onEdit() }
            Button("Mark as mine") { onClaim() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .onTapGesture(count: 2) { onEdit() }
        .accessibilityAction(named: Text("Edit task")) { onEdit() }
        .focusable()
        .onKeyPress(.return) { onEdit(); return .handled }
    }
}

// MARK: - Insights chart

private struct TaskInsightsChart: View {
    @Environment(\.colorScheme) private var scheme

    let insights: [TaskDayInsight]
    let accent: Color

    private var maxTotal: Int {
        max(1, insights.map(\.total).max() ?? 0)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(insights, id: \.date) { insight in
                VStack(spacing: 4) {
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(accent.opacity(0.8))
                            .frame(height: barHeight(insight.completed))
                        Rectangle()
                            .fill(accent.opacity(0.2))
                            .frame(height: barHeight(insight.pending))
                    }
                    Text(dayLabel(insight.date))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barHeight(_ count: Int) -> CGFloat {
        guard maxTotal > 0 else { return 0 }
        return CGFloat(count) / CGFloat(maxTotal) * 48
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return String(formatter.string(from: date).prefix(2))
    }
}

// MARK: - Add/Edit sheet

struct TaskEditSheet: View {
    let task: TrackedTask?
    let onSave: (TrackedTask) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var detail: String
    @State private var owner: String
    @State private var isMine: Bool
    @State private var priority: TaskPriority
    @State private var tags: [String]
    @State private var dueDate: Date?

    init(task: TrackedTask?, onSave: @escaping (TrackedTask) -> Void) {
        self.task = task
        self.onSave = onSave
        _text = State(initialValue: task?.text ?? "")
        _detail = State(initialValue: task?.detail ?? "")
        _owner = State(initialValue: task?.owner ?? AppSettings.currentUserName)
        _isMine = State(initialValue: task?.isMine ?? true)
        _priority = State(initialValue: task?.priority ?? .normal)
        _tags = State(initialValue: task?.tags ?? [])
        _dueDate = State(initialValue: task?.dueDate)
    }

    private var isEditing: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Task" : "New Task")
                .font(.nutola(16, .bold))
                .foregroundStyle(Theme.heading(scheme))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Task", text: $text)
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $detail, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...)

                HStack(spacing: 12) {
                    TextField("Owner", text: $owner)
                        .textFieldStyle(.roundedBorder)

                    Picker("Priority", selection: $priority) {
                        ForEach(TaskPriority.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle("This is my task", isOn: $isMine)
                    .font(.nutola(12))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") { saveAndDismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.mint(scheme))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func saveAndDismiss() {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        guard !trimmedText.isEmpty else { return }

        if var existing = task {
            existing.text = trimmedText
            existing.detail = detail.isEmpty ? nil : detail
            existing.owner = owner.isEmpty ? nil : owner
            existing.isMine = isMine
            if existing.priority != priority {
                existing.priority = priority
                existing.priorityOverridden = true
            }
            existing.tags = tags
            existing.dueDate = dueDate
            onSave(existing)
        } else {
            let newTask = TrackedTask(
                text: trimmedText,
                detail: detail.isEmpty ? nil : detail,
                owner: owner.isEmpty ? nil : owner,
                isMine: isMine,
                priority: priority,
                priorityOverridden: true,
                isChecked: false,
                source: nil,
                tags: tags,
                createdAt: Date(),
                completedAt: nil,
                dueDate: dueDate,
                calendarEventID: nil)
            onSave(newTask)
        }
        dismiss()
    }
}

// MARK: - Rename sheet

private struct RenameOwnerSheet: View {
    let from: String
    let onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName: String

    init(from: String, onRename: @escaping (String) -> Void) {
        self.from = from
        self.onRename = onRename
        _newName = State(initialValue: from)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename owner")
                .font(.nutola(16, .bold))
            Text("This will update all tasks assigned to \(from).")
                .font(.nutola(12))
                .foregroundStyle(.secondary)
            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Rename") {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onRename(trimmed) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

// MARK: - Merge owner sheet

private struct MergeOwnerSheet: View {
    let from: String
    let existingOwners: [String]
    let onMerge: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var target: String
    @State private var useExisting = false

    init(
        from: String,
        existingOwners: [String],
        onMerge: @escaping (String) -> Void
    ) {
        self.from = from
        self.existingOwners = existingOwners
        self.onMerge = onMerge
        let others = existingOwners.filter { $0.lowercased() != from.lowercased() }
        _target = State(initialValue: others.first ?? "")
        _useExisting = State(initialValue: !others.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge owners")
                .font(.nutola(16, .bold))
                .foregroundStyle(Theme.heading(scheme))
            Text("Merge \"\(from)\" into another owner. All their tasks will be reassigned.")
                .font(.nutola(12))
                .foregroundStyle(.secondary)

            let others = existingOwners.filter {
                $0.lowercased() != from.lowercased()
            }
            if !others.isEmpty {
                Toggle("Merge into existing owner", isOn: $useExisting)
                    .font(.nutola(12))
                if useExisting {
                    Picker("Owner", selection: $target) {
                        ForEach(others, id: \.self) { owner in
                            Text(owner).tag(owner)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    TextField("New owner name", text: $target)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                TextField("New owner name", text: $target)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Merge") {
                    let trimmed = target.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onMerge(trimmed) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.mint(scheme))
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
