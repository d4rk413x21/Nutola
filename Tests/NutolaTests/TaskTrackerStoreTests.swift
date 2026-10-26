import Foundation
import Testing
@testable import Nutola

final class TaskTrackerStoreTests {
    private let suite = "task-tracker-tests-\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var store: TaskTrackerStore!

    init() {
        defaults = UserDefaults(suiteName: suite)!
        store = TaskTrackerStore(defaults: defaults, key: "test-tracker")
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Add

    @Test func testAddTask() {
        _ = store.add(text: "Review PR", priority: .high)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.text == "Review PR")
        #expect(store.tasks.first?.priority == .high)
        #expect(!(store.tasks.first?.isChecked ?? true))
        #expect(!(store.tasks.first?.priorityOverridden ?? true))
    }

    @Test func testAddWithDefaults() {
        let task = store.add(text: "Test")
        #expect(task.priority == .normal)
        #expect(task.detail == nil)
        #expect(task.isMine)
    }

    // MARK: - Toggle

    @Test func testToggleMarksComplete() {
        let task = store.add(text: "Do something")
        #expect(store.tasks.first?.completedAt == nil)
        store.toggle(id: task.id)
        #expect(store.tasks.first?.isChecked ?? false)
        #expect(store.tasks.first?.completedAt != nil)
        // Toggle back
        store.toggle(id: task.id)
        #expect(!(store.tasks.first?.isChecked ?? true))
        #expect(store.tasks.first?.completedAt == nil)
    }

    // MARK: - Update

    @Test func testUpdatePreservesId() {
        let task = store.add(text: "Original")
        var modified = task
        modified.text = "Updated"
        store.update(modified)
        #expect(store.tasks.first?.text == "Updated")
        #expect(store.tasks.first?.id == task.id)
    }

    @Test func testPriorityOverrideSticks() {
        let task = store.add(text: "Task", priority: .normal)
        var modified = task
        modified.priority = .urgent
        store.update(modified)
        #expect(store.tasks.first?.priorityOverridden ?? false)
    }

    // MARK: - Delete

    @Test func testDeleteTask() {
        let task = store.add(text: "To delete")
        #expect(store.tasks.count == 1)
        store.delete(id: task.id)
        #expect(store.tasks.isEmpty)
    }

    // MARK: - Rename owner

    @Test func testRenameOwner() {
        store.add(text: "Task 1", owner: "Speaker 17", isMine: false)
        store.add(text: "Task 2", owner: "Speaker 17", isMine: false)
        store.add(text: "Task 3", owner: "Alice", isMine: false)

        let count = store.renameOwner(from: "Speaker 17", to: "Gui Lima")
        #expect(count == 2)
        #expect(store.tasks.filter { $0.owner == "Gui Lima" }.count == 2)
        #expect(store.tasks.filter { $0.owner == "Alice" }.count == 1)
    }

    @Test func testRenameOwnerCaseInsensitive() {
        store.add(text: "Task", owner: "John Doe", isMine: false)
        let count = store.renameOwner(from: "john doe", to: "Jane")
        #expect(count == 1)
        #expect(store.tasks.first?.owner == "Jane")
    }

    // MARK: - Clear completed

    @Test func testClearCompleted() {
        let task1 = store.add(text: "Done")
        store.toggle(id: task1.id)
        _ = store.add(text: "Still open")
        #expect(store.tasks.count == 2)
        store.clearCompleted()
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.text == "Still open")
    }

    // MARK: - Sync from meeting

    @Test func testSyncFromMeetingCreatesTasks() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        let summary = """
        # Meeting Notes

        - [ ] Review PR — Alice
        - [ ] Fix bug — Bob
        - [x] Already done
        """
        store.syncFromMeeting(meeting, summary: summary, currentUser: "Taylor")

        #expect(store.tasks.count == 3)
        #expect(store.tasks.contains { $0.text == "Review PR" && $0.owner == "Alice" })
        #expect(store.tasks.contains { $0.text == "Fix bug" && $0.owner == "Bob" })
        #expect(store.tasks.contains { $0.text == "Already done" && $0.isChecked })
    }

    @Test func testSyncUpdatesExistingTasks() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        let summary1 = "- [ ] Review PR — Alice"
        store.syncFromMeeting(meeting, summary: summary1, currentUser: "Me")
        #expect(store.tasks.count == 1)

        // Re-sync with same text — should not duplicate.
        store.syncFromMeeting(meeting, summary: summary1, currentUser: "Me")
        #expect(store.tasks.count == 1)
    }

    @Test func testSyncDifferentTextCreatesNewTask() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        store.syncFromMeeting(meeting, summary: "- [ ] Review PR — Alice", currentUser: "Me")
        #expect(store.tasks.count == 1)

        // Different action item text → new task.
        store.syncFromMeeting(meeting, summary: "- [ ] Review PR and merge — Alice", currentUser: "Me")
        #expect(store.tasks.count == 2)
    }

    @Test func testSyncDoesNotReopenCheckedTasks() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        store.syncFromMeeting(meeting, summary: "- [ ] Fix bug — Me", currentUser: "Me")
        store.toggle(id: store.tasks.first!.id)
        #expect(store.tasks.first?.isChecked ?? false)

        // Re-sync — the checked task should stay checked.
        store.syncFromMeeting(meeting, summary: "- [ ] Fix bug — Me", currentUser: "Me")
        #expect(store.tasks.first?.isChecked ?? false)
    }

    @Test func testSyncPreservesOverriddenPriority() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        store.syncFromMeeting(meeting, summary: "- [ ] urgent fix — Me", currentUser: "Me")
        #expect(store.tasks.first?.priority == .urgent)

        // User overrides to low.
        var task = store.tasks.first!
        task.priority = .low
        store.update(task)
        #expect(store.tasks.first?.priorityOverridden ?? false)

        // Re-sync — should NOT override the user's priority.
        store.syncFromMeeting(meeting, summary: "- [ ] urgent fix — Me", currentUser: "Me")
        #expect(store.tasks.first?.priority == .low)
    }

    // MARK: - Remove tasks for meeting

    @Test func testRemoveTasksForMeeting() {
        let meeting1 = Meeting(title: "Meeting 1", createdAt: Date())
        let meeting2 = Meeting(title: "Meeting 2", createdAt: Date())
        store.syncFromMeeting(meeting1, summary: "- [ ] Task A — Me", currentUser: "Me")
        store.syncFromMeeting(meeting2, summary: "- [ ] Task B — Me", currentUser: "Me")
        #expect(store.tasks.count == 2)

        store.removeTasks(forMeetingID: meeting1.id)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.text == "Task B")
    }

    // MARK: - Ownership claim

    @Test func testClaimOwnership() {
        store.add(text: "Task", owner: "Unknown", isMine: false)
        store.claimOwnership(id: store.tasks.first!.id)
        #expect(store.tasks.first?.isMine ?? false)
    }

    // MARK: - Priority heuristics

    @Test func testPriorityUrgentKeywords() {
        #expect(TaskPriorityHeuristics.assess(for: "Fix this urgently", owner: "Me") == .urgent)
        #expect(TaskPriorityHeuristics.assess(for: "This is a blocker", owner: "Me") == .urgent)
        #expect(TaskPriorityHeuristics.assess(for: "ASAP please", owner: nil) == .urgent)
    }

    @Test func testPriorityHighKeywords() {
        #expect(TaskPriorityHeuristics.assess(for: "Review the design", owner: "Me") == .high)
        #expect(TaskPriorityHeuristics.assess(for: "Deploy today", owner: "Me") == .high)
        #expect(TaskPriorityHeuristics.assess(for: "Fix the bug", owner: "Me") == .high)
    }

    @Test func testPriorityLowKeywords() {
        #expect(TaskPriorityHeuristics.assess(for: "Maybe explore this", owner: "Me") == .low)
        #expect(TaskPriorityHeuristics.assess(for: "Nice to have", owner: "Me") == .low)
    }

    @Test func testPriorityNormalFallback() {
        #expect(TaskPriorityHeuristics.assess(for: "Update the doc", owner: "Me") == .normal)
    }

    @Test func testPriorityHighForUnassigned() {
        #expect(TaskPriorityHeuristics.assess(for: "Some random task", owner: nil) == .high)
    }

    // MARK: - Insights

    @Test func testDailyInsights() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 12))!

        // Create 3 tasks on the anchor day (createdAt pinned so the test is
        // deterministic regardless of the real wall-clock date).
        _ = store.add(text: "Task A", createdAt: now)
        _ = store.add(text: "Task B", createdAt: now)
        let taskC = store.add(text: "Task C", createdAt: now)

        // Complete one (pinned to the same anchor day).
        store.toggle(id: taskC.id, at: now)

        let insights = store.dailyInsights(for: 1, calendar: cal, from: now)
        #expect(insights.count == 1)
        #expect(insights.first?.total == 3)
        #expect(insights.first?.completed == 1)
        #expect(insights.first?.pending == 2)
    }

    @Test func testCompletionRate() {
        let task1 = store.add(text: "A")
        let task2 = store.add(text: "B")
        _ = store.add(text: "C")
        store.toggle(id: task1.id)
        store.toggle(id: task2.id)
        #expect(abs((store.completionRate) - (2.0 / 3.0)) <= 0.01)
        #expect(store.completedCount == 2)
        #expect(store.openCount == 1)
    }

    // MARK: - Persistence

    @Test func testPersistence() {
        store.add(text: "Persisted task")
        let store2 = TaskTrackerStore(defaults: defaults, key: "test-tracker")
        #expect(store2.tasks.count == 1)
        #expect(store2.tasks.first?.text == "Persisted task")
    }

    // MARK: - Owners list

    @Test func testOwnersList() {
        store.add(text: "A", owner: "Alice", isMine: false)
        store.add(text: "B", owner: "Bob", isMine: false)
        store.add(text: "C", owner: "Alice", isMine: false)
        let owners = store.owners
        #expect(owners == ["Alice", "Bob"])
    }

    // MARK: - Sorted tasks

    @Test func testSortedTasksByPriority() {
        store.add(text: "Normal", priority: .normal)
        store.add(text: "Urgent", priority: .urgent)
        store.add(text: "Low", priority: .low)
        store.add(text: "High", priority: .high)

        let sorted = store.sortedTasks.map(\.text)
        #expect(sorted == ["Urgent", "High", "Normal", "Low"])
    }
}
