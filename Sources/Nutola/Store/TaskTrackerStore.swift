import Foundation
import SwiftUI

/// A tracked activity — either synced from a meeting's action items or
/// created manually by the user. Persists across launches in UserDefaults.
struct TrackedTask: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var text: String
    /// Longer description or context the user can add.
    var detail: String?
    /// Owner of the task (assignee). Defaults to the current user; unknown
    /// speakers from meeting summaries may appear as "Speaker 17" until
    /// the user renames them.
    var owner: String?
    /// True when the owner is the current user (used for default filtering).
    /// Stored so the filter survives a rename.
    var isMine: Bool
    /// AI-assigned priority; the user can override.
    var priority: TaskPriority
    /// Whether the user has overridden the AI priority. When true, sync no
    /// longer touches `priority` — the user's choice sticks.
    var priorityOverridden: Bool
    var isChecked: Bool
    /// Where this task came from: a meeting id + title for reference.
    var source: TaskSource?
    /// Tags for cross-cutting categorization (e.g. "prep", "follow-up").
    var tags: [String]
    var createdAt: Date
    var completedAt: Date?
    var dueDate: Date?
    /// Linked upcoming calendar event (for prep tasks).
    var calendarEventID: String?
}

/// Provenance of a tracked task: which meeting it was synced from.
struct TaskSource: Codable, Equatable, Sendable {
    var meetingID: UUID
    var meetingTitle: String
}

enum TaskPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case urgent
    case high
    case normal
    case low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .urgent: "Urgent"
        case .high: "High"
        case .normal: "Normal"
        case .low: "Low"
        }
    }

    var sortOrder: Int {
        switch self {
        case .urgent: 0
        case .high: 1
        case .normal: 2
        case .low: 3
        }
    }

    var systemImage: String {
        switch self {
        case .urgent: "exclamationmark.octagon.fill"
        case .high: "exclamationmark.circle.fill"
        case .normal: "circle.fill"
        case .low: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .urgent: .red
        case .high: .orange
        case .normal: .blue
        case .low: .gray
        }
    }
}

/// One day's snapshot of task activity — used by the insights chart.
struct TaskDayInsight: Equatable, Sendable {
    let date: Date
    let total: Int
    let completed: Int
    let pending: Int
}

/// A merge rule: raw owner labels matching `from` (case-insensitive) are
/// displayed and stored as `to`. Lets the user merge "You/Taylor" →
/// "Taylor" or rename "Speaker 11" → "Victor" across all tasks.
struct OwnerAlias: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var from: String
    var to: String
}

/// Observable, UserDefaults-backed store for the activity tracker.
///
/// `TrackedTask`s are synced from meeting summaries' action-item checkboxes
/// and can also be created manually. The store keys each task by a stable
/// `syncKey` so re-syncs from the same meeting update in place rather than
/// duplicating. Tasks the user has checked off are never re-opened by sync.
final class TaskTrackerStore: ObservableObject {
    @Published private(set) var tasks: [TrackedTask]
    @Published private(set) var aliases: [OwnerAlias]

    private let defaults: UserDefaults
    private let key: String
    private let aliasKey: String

    init(
        defaults: UserDefaults = .standard,
        key: String = SettingsKey.taskTracker,
        aliasKey: String = SettingsKey.ownerAliases
    ) {
        self.defaults = defaults
        self.key = key
        self.aliasKey = aliasKey
        self.tasks = Self.loadTasks(from: defaults, key: key)
        self.aliases = Self.loadAliases(from: defaults, key: aliasKey)
    }

    // MARK: - Alias resolution

    /// Resolve a raw owner name through the alias map. Returns the
    /// canonical name if a rule matches (case-insensitive), else the
    /// original name unchanged.
    func resolveOwner(_ raw: String) -> String {
        for alias in aliases {
            if alias.from.lowercased() == raw.lowercased() {
                return alias.to
            }
        }
        return raw
    }

    /// Add or update an alias rule. If a rule with the same `from` already
    /// exists, its `to` is updated. Also rewrites all existing task owners.
    @discardableResult
    func addAlias(from: String, to: String) -> OwnerAlias {
        if let index = aliases.firstIndex(where: {
            $0.from.lowercased() == from.lowercased()
        }) {
            aliases[index].to = to
        } else {
            aliases.append(OwnerAlias(from: from, to: to))
        }
        // Apply to all existing tasks.
        for index in tasks.indices {
            if let owner = tasks[index].owner {
                tasks[index].owner = resolveOwner(owner)
            }
        }
        persist()
        return aliases.last!
    }

    /// Remove an alias rule by id.
    func removeAlias(id: UUID) {
        aliases.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Reads

    /// All tasks, sorted by priority then creation time.
    var sortedTasks: [TrackedTask] {
        tasks
            .sorted { lhs, rhs in
                if lhs.priority.sortOrder != rhs.priority.sortOrder {
                    return lhs.priority.sortOrder < rhs.priority.sortOrder
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Distinct resolved owner names, sorted alphabetically.
    var owners: [String] {
        let names = Set(tasks.compactMap { $0.owner }.map { resolveOwner($0) })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Distinct tag names across all tasks.
    var allTags: [String] {
        let tags = Set(tasks.flatMap(\.tags))
        return tags.sorted()
    }

    /// Count of open (unchecked) tasks.
    var openCount: Int { tasks.filter { !$0.isChecked }.count }

    /// Count of completed tasks.
    var completedCount: Int { tasks.filter { $0.isChecked }.count }

    // MARK: - Writes

    /// Add a task manually. Returns the created task.
    @discardableResult
    func add(
        text: String,
        detail: String? = nil,
        owner: String? = nil,
        isMine: Bool = true,
        priority: TaskPriority = .normal,
        tags: [String] = [],
        dueDate: Date? = nil,
        source: TaskSource? = nil,
        calendarEventID: String? = nil,
        createdAt: Date = Date()
    ) -> TrackedTask {
        var task = TrackedTask(
            text: text,
            detail: detail,
            owner: owner,
            isMine: isMine,
            priority: priority,
            priorityOverridden: false,
            isChecked: false,
            source: source,
            tags: tags,
            createdAt: createdAt,
            completedAt: nil,
            dueDate: dueDate,
            calendarEventID: calendarEventID)
        if isMine && owner == nil { task.owner = AppSettings.currentUserName }
        tasks.append(task)
        persist()
        return task
    }

    /// Update a task in place. No-op if the id isn't found.
    func update(_ task: TrackedTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var updated = task
        if updated.priorityOverridden == false, task.priority != tasks[index].priority {
            updated.priorityOverridden = true
        }
        if updated.isChecked && !tasks[index].isChecked {
            updated.completedAt = Date()
        } else if !updated.isChecked && tasks[index].isChecked {
            updated.completedAt = nil
        }
        tasks[index] = updated
        persist()
    }

    /// Toggle the checkbox on a task.
    func toggle(id: UUID, at: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isChecked.toggle()
        tasks[index].completedAt = tasks[index].isChecked ? at : nil
        persist()
    }

    /// Delete a task by id.
    func delete(id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    /// Rename an owner across all tasks. Used to fix "Speaker 17" → real name.
    @discardableResult
    func renameOwner(from oldName: String, to newName: String) -> Int {
        let normalizedOld = oldName.lowercased().trimmingCharacters(in: .whitespaces)
        var count = 0
        for index in tasks.indices {
            guard let owner = tasks[index].owner,
                  owner.lowercased().trimmingCharacters(in: .whitespaces) == normalizedOld
            else { continue }
            tasks[index].owner = newName
            count += 1
        }
        if count > 0 { persist() }
        return count
    }

    /// Mark a task as mine (for filtering) after the user claims an unknown task.
    func claimOwnership(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isMine = true
        if tasks[index].owner == nil {
            tasks[index].owner = AppSettings.currentUserName
        }
        persist()
    }

    /// Remove all completed tasks.
    func clearCompleted() {
        tasks.removeAll { $0.isChecked }
        persist()
    }

    // MARK: - Sync from meetings

    /// Sync action items from a meeting summary into the tracker. Tasks that
    /// already exist (matched by `syncKey`) are updated in place — but a
    /// checked task is never re-opened, and a user-overridden priority is
    /// preserved. New action items are added with an AI-assigned priority.
    func syncFromMeeting(
        _ meeting: Meeting,
        summary: String,
        currentUser: String = AppSettings.currentUserName
    ) {
        let items = ActionItemParser.parse(summary)
        guard !items.isEmpty else { return }
        let source = TaskSource(meetingID: meeting.id, meetingTitle: meeting.title)

        for item in items {
            let rawOwner = item.owner ?? currentUser
            let owner = resolveOwner(rawOwner)
            let isMine = owner.lowercased() == currentUser.lowercased()
            let priority = TaskPriorityHeuristics.assess(
                for: item.text, owner: item.owner)
            let matchKey = item.text.lowercased()
                .trimmingCharacters(in: .whitespaces)
            let existing = tasks.firstIndex {
                $0.source?.meetingID == meeting.id
                    && $0.text.lowercased()
                        .trimmingCharacters(in: .whitespaces) == matchKey
            }

            if let existing {
                // Update text/owner but preserve checkbox and overridden priority.
                tasks[existing].text = item.text
                if tasks[existing].owner != owner && !tasks[existing].isMine {
                    tasks[existing].owner = owner
                }
                tasks[existing].source = source
                if !tasks[existing].priorityOverridden {
                    tasks[existing].priority = priority
                }
            } else {
                let task = TrackedTask(
                    text: item.text,
                    detail: nil,
                    owner: owner,
                    isMine: isMine,
                    priority: priority,
                    priorityOverridden: false,
                    isChecked: item.isChecked,
                    source: source,
                    tags: [],
                    createdAt: Date(),
                    completedAt: item.isChecked ? Date() : nil,
                    dueDate: nil,
                    calendarEventID: nil)
                tasks.append(task)
            }
        }
        persist()
    }

    /// Remove all tasks sourced from a deleted meeting.
    func removeTasks(forMeetingID id: UUID) {
        tasks.removeAll { $0.source?.meetingID == id }
        persist()
    }

    // MARK: - Insights

    /// Daily task insights for a date range. Each entry has the total tasks
    /// created that day and how many were completed (on any day, but attributed
    /// to their completion date).
    func dailyInsights(
        for days: Int = 7,
        calendar: Calendar = .current,
        from anchorDate: Date = .now
    ) -> [TaskDayInsight] {
        let startDate = calendar.startOfDay(for: anchorDate)
        guard let endDate = calendar.date(byAdding: .day, value: days, to: startDate) else { return [] }

        var insights: [TaskDayInsight] = []
        var dayIndex = 0
        while dayIndex < days {
            guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: startDate) else { break }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }

            let created = tasks.filter {
                $0.createdAt >= dayStart && $0.createdAt < dayEnd
            }.count
            let completed = tasks.filter {
                if let completedAt = $0.completedAt {
                    return completedAt >= dayStart && completedAt < dayEnd
                }
                return false
            }.count

            insights.append(TaskDayInsight(
                date: dayStart,
                total: created,
                completed: completed,
                pending: created - completed))
            dayIndex += 1
        }
        _ = endDate  // endDate bounds the range but isn't used in the loop.
        return insights
    }

    /// Completion rate as a percentage (0-1).
    var completionRate: Double {
        guard !tasks.isEmpty else { return 0 }
        return Double(completedCount) / Double(tasks.count)
    }

    // MARK: - Private

    private func persist() {
        objectWillChange.send()
        do {
            let taskData = try JSONEncoder().encode(tasks)
            let aliasData = try JSONEncoder().encode(aliases)
            defaults.set(taskData, forKey: key)
            defaults.set(aliasData, forKey: aliasKey)
        } catch { PersistenceStatus.record(error) }
    }

    private static func loadTasks(
        from defaults: UserDefaults, key: String
    ) -> [TrackedTask] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode(
            [TrackedTask].self, from: data)) ?? []
    }

    private static func loadAliases(
        from defaults: UserDefaults, key: String
    ) -> [OwnerAlias] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode(
            [OwnerAlias].self, from: data)) ?? []
    }
}

// MARK: - Priority heuristics

/// Lightweight, deterministic heuristics for assigning a priority to a task
/// based on its text content and owner. No external AI calls — purely
/// keyword-based so it runs instantly and is unit-testable.
enum TaskPriorityHeuristics {
    static func assess(for text: String, owner: String?) -> TaskPriority {
        let lower = text.lowercased()

        // Urgent keywords.
        let urgent = ["urgent", "asap", "critical", "blocker", "blocking", "immediately", "hotfix"]
        if urgent.contains(where: { lower.contains($0) }) { return .urgent }

        // High-priority keywords.
        let high = ["review", "approve", "deadline", "today", "fix", "debug", "deploy", "merge", "ship"]
        if high.contains(where: { lower.contains($0) }) { return .high }

        // Low-priority keywords.
        let low = ["someday", "maybe", "consider", "explore", "optional", "nice to have", "read", "browse"]
        if low.contains(where: { lower.contains($0) }) { return .low }

        // Unassigned tasks get normal priority, but tasks with no owner
        // (meaning nobody has claimed them yet) get a slight bump.
        if owner == nil { return .high }
        return .normal
    }
}
