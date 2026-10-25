import XCTest
@testable import Nutola

final class TaskTrackerStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: TaskTrackerStore!

    override func setUp() {
        super.setUp()
        let suite = "task-tracker-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = TaskTrackerStore(defaults: defaults, key: "test-tracker")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionary(forKey: "suite")?.first?.key as? String ?? "")
        super.tearDown()
    }

    // MARK: - Add

    func testAddTask() {
        _ = store.add(text: "Review PR", priority: .high)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.text, "Review PR")
        XCTAssertEqual(store.tasks.first?.priority, .high)
        XCTAssertFalse(store.tasks.first?.isChecked ?? true)
        XCTAssertFalse(store.tasks.first?.priorityOverridden ?? true)
    }

    func testAddWithDefaults() {
        let task = store.add(text: "Test")
        XCTAssertEqual(task.priority, .normal)
        XCTAssertNil(task.detail)
        XCTAssertTrue(task.isMine)
    }

    // MARK: - Toggle

    func testToggleMarksComplete() {
        let task = store.add(text: "Do something")
        XCTAssertNil(store.tasks.first?.completedAt)
        store.toggle(id: task.id)
        XCTAssertTrue(store.tasks.first?.isChecked ?? false)
        XCTAssertNotNil(store.tasks.first?.completedAt)
        // Toggle back
        store.toggle(id: task.id)
        XCTAssertFalse(store.tasks.first?.isChecked ?? true)
        XCTAssertNil(store.tasks.first?.completedAt)
    }

    // MARK: - Update

    func testUpdatePreservesId() {
        let task = store.add(text: "Original")
        var modified = task
        modified.text = "Updated"
        store.update(modified)
        XCTAssertEqual(store.tasks.first?.text, "Updated")
        XCTAssertEqual(store.tasks.first?.id, task.id)
    }

    func testPriorityOverrideSticks() {
        let task = store.add(text: "Task", priority: .normal)
        var modified = task
        modified.priority = .urgent
        store.update(modified)
        XCTAssertTrue(store.tasks.first?.priorityOverridden ?? false)
    }

    // MARK: - Delete

    func testDeleteTask() {
        let task = store.add(text: "To delete")
        XCTAssertEqual(store.tasks.count, 1)
        store.delete(id: task.id)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    // MARK: - Rename owner

    func testRenameOwner() {
        store.add(text: "Task 1", owner: "Speaker 17", isMine: false)
        store.add(text: "Task 2", owner: "Speaker 17", isMine: false)
        store.add(text: "Task 3", owner: "Alice", isMine: false)

        let count = store.renameOwner(from: "Speaker 17", to: "Gui Lima")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.tasks.filter { $0.owner == "Gui Lima" }.count, 2)
        XCTAssertEqual(store.tasks.filter { $0.owner == "Alice" }.count, 1)
    }

    func testRenameOwnerCaseInsensitive() {
        store.add(text: "Task", owner: "John Doe", isMine: false)
        let count = store.renameOwner(from: "john doe", to: "Jane")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.tasks.first?.owner, "Jane")
    }

    // MARK: - Clear completed

    func testClearCompleted() {
        let task1 = store.add(text: "Done")
        store.toggle(id: task1.id)
        _ = store.add(text: "Still open")
        XCTAssertEqual(store.tasks.count, 2)
        store.clearCompleted()
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.text, "Still open")
    }

    // MARK: - Sync from meeting

    func testSyncFromMeetingCreatesTasks() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        let summary = """
        # Meeting Notes

        - [ ] Review PR — Alice
        - [ ] Fix bug — Bob
        - [x] Already done
        """
        store.syncFromMeeting(meeting, summary: summary, currentUser: "Taylor")

        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertTrue(store.tasks.contains { $0.text == "Review PR" && $0.owner == "Alice" })
        XCTAssertTrue(store.tasks.contains { $0.text == "Fix bug" && $0.owner == "Bob" })
        XCTAssertTrue(store.tasks.contains { $0.text == "Already done" && $0.isChecked })
    }

    func testSyncUpdatesExistingTasks() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        let summary1 = "- [ ] Review PR — Alice"
        store.syncFromMeeting(meeting, summary: summary1, currentUser: "Me")
        XCTAssertEqual(store.tasks.count, 1)

        // Re-sync with same text — should not duplicate.
        store.syncFromMeeting(meeting, summary: summary1, currentUser: "Me")
        XCTAssertEqual(store.tasks.count, 1)
    }

    func testSyncDifferentTextCreatesNewTask() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        store.syncFromMeeting(meeting, summary: "- [ ] Review PR — Alice", currentUser: "Me")
        XCTAssertEqual(store.tasks.count, 1)

        // Different action item text → new task.
        store.syncFromMeeting(meeting, summary: "- [ ] Review PR and merge — Alice", currentUser: "Me")
        XCTAssertEqual(store.tasks.count, 2)
    }

    func testSyncDoesNotReopenCheckedTasks() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        store.syncFromMeeting(meeting, summary: "- [ ] Fix bug — Me", currentUser: "Me")
        store.toggle(id: store.tasks.first!.id)
        XCTAssertTrue(store.tasks.first?.isChecked ?? false)

        // Re-sync — the checked task should stay checked.
        store.syncFromMeeting(meeting, summary: "- [ ] Fix bug — Me", currentUser: "Me")
        XCTAssertTrue(store.tasks.first?.isChecked ?? false)
    }

    func testSyncPreservesOverriddenPriority() {
        let meeting = Meeting(title: "Standup", createdAt: Date())
        store.syncFromMeeting(meeting, summary: "- [ ] urgent fix — Me", currentUser: "Me")
        XCTAssertEqual(store.tasks.first?.priority, .urgent)

        // User overrides to low.
        var task = store.tasks.first!
        task.priority = .low
        store.update(task)
        XCTAssertTrue(store.tasks.first?.priorityOverridden ?? false)

        // Re-sync — should NOT override the user's priority.
        store.syncFromMeeting(meeting, summary: "- [ ] urgent fix — Me", currentUser: "Me")
        XCTAssertEqual(store.tasks.first?.priority, .low)
    }

    // MARK: - Remove tasks for meeting

    func testRemoveTasksForMeeting() {
        let meeting1 = Meeting(title: "Meeting 1", createdAt: Date())
        let meeting2 = Meeting(title: "Meeting 2", createdAt: Date())
        store.syncFromMeeting(meeting1, summary: "- [ ] Task A — Me", currentUser: "Me")
        store.syncFromMeeting(meeting2, summary: "- [ ] Task B — Me", currentUser: "Me")
        XCTAssertEqual(store.tasks.count, 2)

        store.removeTasks(forMeetingID: meeting1.id)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.text, "Task B")
    }

    // MARK: - Ownership claim

    func testClaimOwnership() {
        store.add(text: "Task", owner: "Unknown", isMine: false)
        store.claimOwnership(id: store.tasks.first!.id)
        XCTAssertTrue(store.tasks.first?.isMine ?? false)
    }

    // MARK: - Priority heuristics

    func testPriorityUrgentKeywords() {
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Fix this urgently", owner: "Me"), .urgent)
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "This is a blocker", owner: "Me"), .urgent)
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "ASAP please", owner: nil), .urgent)
    }

    func testPriorityHighKeywords() {
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Review the design", owner: "Me"), .high)
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Deploy today", owner: "Me"), .high)
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Fix the bug", owner: "Me"), .high)
    }

    func testPriorityLowKeywords() {
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Maybe explore this", owner: "Me"), .low)
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Nice to have", owner: "Me"), .low)
    }

    func testPriorityNormalFallback() {
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Update the doc", owner: "Me"), .normal)
    }

    func testPriorityHighForUnassigned() {
        XCTAssertEqual(TaskPriorityHeuristics.assess(for: "Some random task", owner: nil), .high)
    }

    // MARK: - Insights

    func testDailyInsights() {
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
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights.first?.total, 3)
        XCTAssertEqual(insights.first?.completed, 1)
        XCTAssertEqual(insights.first?.pending, 2)
    }

    func testCompletionRate() {
        let task1 = store.add(text: "A")
        let task2 = store.add(text: "B")
        _ = store.add(text: "C")
        store.toggle(id: task1.id)
        store.toggle(id: task2.id)
        XCTAssertEqual(store.completionRate, 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(store.completedCount, 2)
        XCTAssertEqual(store.openCount, 1)
    }

    // MARK: - Persistence

    func testPersistence() {
        store.add(text: "Persisted task")
        let store2 = TaskTrackerStore(defaults: defaults, key: "test-tracker")
        XCTAssertEqual(store2.tasks.count, 1)
        XCTAssertEqual(store2.tasks.first?.text, "Persisted task")
    }

    // MARK: - Owners list

    func testOwnersList() {
        store.add(text: "A", owner: "Alice", isMine: false)
        store.add(text: "B", owner: "Bob", isMine: false)
        store.add(text: "C", owner: "Alice", isMine: false)
        let owners = store.owners
        XCTAssertEqual(owners, ["Alice", "Bob"])
    }

    // MARK: - Sorted tasks

    func testSortedTasksByPriority() {
        store.add(text: "Normal", priority: .normal)
        store.add(text: "Urgent", priority: .urgent)
        store.add(text: "Low", priority: .low)
        store.add(text: "High", priority: .high)

        let sorted = store.sortedTasks.map(\.text)
        XCTAssertEqual(sorted, ["Urgent", "High", "Normal", "Low"])
    }
}
