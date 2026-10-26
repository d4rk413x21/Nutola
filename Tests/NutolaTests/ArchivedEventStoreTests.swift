import Foundation
import Testing
@testable import Nutola

final class ArchivedEventStoreTests {
    private var defaults: UserDefaults!
    private let suiteName = "test-archived-events-\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> ArchivedEventStore {
        ArchivedEventStore(
            defaults: defaults,
            titlesKey: "test-archived-titles",
            idsKey: "test-archived-ids"
        )
    }

    // MARK: - Title (series) archiving

    @Test func testArchiveTitle() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        #expect(store.isTitleArchived("Lunch time"))
        #expect(!(store.isTitleArchived("Standup")))
    }

    @Test func testArchiveTitleTrimsWhitespace() {
        let store = makeStore()
        store.archiveTitle("  Lunch time  ")
        #expect(store.isTitleArchived("Lunch time"))
    }

    @Test func testArchiveEmptyTitleIsNoOp() {
        let store = makeStore()
        store.archiveTitle("   ")
        #expect(store.archivedTitles.isEmpty)
    }

    @Test func testUnarchiveTitle() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.unarchiveTitle("Lunch time")
        #expect(!(store.isTitleArchived("Lunch time")))
    }

    // MARK: - Event ID archiving

    @Test func testArchiveEventByID() {
        let store = makeStore()
        let id = UUID().uuidString
        store.archiveEvent(id: id, title: "Test Event")
        #expect(store.isEventArchived(id: id))
        #expect(!(store.isEventArchived(id: "other")))
    }

    @Test func testUnarchiveEventByID() {
        let store = makeStore()
        let id = UUID().uuidString
        store.archiveEvent(id: id, title: "Test Event")
        store.unarchiveEvent(id: id)
        #expect(!(store.isEventArchived(id: id)))
    }

    // MARK: - Combined filtering

    @Test func testIsArchivedByTitle() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        #expect(store.isArchived(title: "Lunch time", eventID: "abc"))
    }

    @Test func testIsArchivedByEventID() {
        let store = makeStore()
        store.archiveEvent(id: "evt-123", title: "Some Event")
        #expect(store.isArchived(title: "Other", eventID: "evt-123"))
    }

    @Test func testIsNotArchivedWhenNeitherMatches() {
        let store = makeStore()
        #expect(!(store.isArchived(title: "Lunch time", eventID: "abc")))
    }

    // MARK: - Clear all

    @Test func testClearAll() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.archiveEvent(id: "evt-123", title: "Some Event")
        store.clearAll()
        #expect(store.archivedTitles.isEmpty)
        #expect(store.archivedEvents.isEmpty)
        #expect(!(store.isArchived(title: "Lunch time", eventID: "evt-123")))
    }

    // MARK: - Persistence

    @Test func testTitlesPersistAcrossInstances() {
        let store1 = makeStore()
        store1.archiveTitle("Standup")

        let store2 = makeStore()
        #expect(store2.isTitleArchived("Standup"))
    }

    @Test func testEventIDsPersistAcrossInstances() {
        let store1 = makeStore()
        store1.archiveEvent(id: "evt-456", title: "Persisted Event")

        let store2 = makeStore()
        #expect(store2.isEventArchived(id: "evt-456"))
    }

    // MARK: - Multiple

    @Test func testMultipleTitlesArchived() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.archiveTitle("Standup")
        store.archiveTitle("1:1")
        #expect(store.archivedTitles.count == 3)
    }

    @Test func testDuplicateTitleIsIdempotent() {
        let store = makeStore()
        store.archiveTitle("Lunch time")
        store.archiveTitle("Lunch time")
        #expect(store.archivedTitles.count == 1)
    }
}
