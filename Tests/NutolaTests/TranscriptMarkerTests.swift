import Foundation
import Testing
@testable import Nutola

final class TranscriptMarkerTests {
    var defaults: UserDefaults!
    var store: TranscriptMarkerStore!
    private var suite: String!

    init() {
        // A fresh, isolated UserDefaults suite per test so markers never leak
        // across tests or into the host app's .standard defaults.
        suite = "nutola-markers-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = TranscriptMarkerStore(defaults: defaults)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: - add / markers(for:)

    @Test func testAddMarker() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 42, label: "Important point")

        let markers = store.markers(for: meetingID)
        #expect(markers.count == 1)
        #expect(markers.first?.meetingID == meetingID)
        #expect(abs((markers.first?.timestamp ?? -1) - (42)) <= 0.001)
        #expect(markers.first?.label == "Important point")
        #expect(markers.first?.id != nil)
        #expect(markers.first?.createdAt != nil)
    }

    @Test func testRemoveMarker() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 10, label: "Remove me")
        let id = store.markers(for: meetingID).first!.id

        store.remove(id: id, meetingID: meetingID)
        #expect(store.markers(for: meetingID).isEmpty)
    }

    @Test func testMultipleMarkers() {
        let meetingID = UUID()
        // Add out of timestamp order to verify the read sorts by timestamp.
        store.add(meetingID: meetingID, timestamp: 30, label: "C")
        store.add(meetingID: meetingID, timestamp: 5, label: "A")
        store.add(meetingID: meetingID, timestamp: 20, label: "B")

        let markers = store.markers(for: meetingID)
        #expect(markers.count == 3)
        // Sorted by timestamp ascending.
        #expect(markers.map(\.label) == ["A", "B", "C"])
        #expect(markers.map(\.timestamp) == [5, 20, 30])
    }

    @Test func testMarkersForDifferentMeetings() {
        let m1 = UUID()
        let m2 = UUID()

        store.add(meetingID: m1, timestamp: 1, label: "Meeting 1 marker")
        #expect(store.markers(for: m1).count == 1)
        // The other meeting must not see this marker.
        #expect(store.markers(for: m2).isEmpty)

        // Adding a marker under m2 leaves m1 alone.
        store.add(meetingID: m2, timestamp: 2, label: "Meeting 2 marker")
        #expect(store.markers(for: m1).count == 1)
        #expect(store.markers(for: m2).count == 1)
        #expect(store.markers(for: m2).first?.label == "Meeting 2 marker")
    }

    // MARK: - isMarked

    @Test func testIsMarked() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 100, label: "Boundary")

        // Exact timestamp is within default tolerance.
        #expect(store.isMarked(meetingID: meetingID, timestamp: 100))
        // Within the default 1.0s tolerance.
        #expect(store.isMarked(meetingID: meetingID, timestamp: 100.5))
        #expect(store.isMarked(meetingID: meetingID, timestamp: 100.9))
        // Just outside the default tolerance.
        #expect(!(store.isMarked(meetingID: meetingID, timestamp: 101.5)))

        // A custom tolerance widens the window.
        #expect(store.isMarked(meetingID: meetingID, timestamp: 103, tolerance: 5))
        #expect(!(store.isMarked(meetingID: meetingID, timestamp: 200, tolerance: 5)))

        // A meeting with no markers is never marked.
        let other = UUID()
        #expect(!(store.isMarked(meetingID: other, timestamp: 100)))
    }

    // MARK: - clear

    @Test func testClearAll() {
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 1, label: "A")
        store.add(meetingID: meetingID, timestamp: 2, label: "B")
        store.add(meetingID: meetingID, timestamp: 3, label: "C")
        #expect(store.markers(for: meetingID).count == 3)

        store.clear(meetingID: meetingID)
        #expect(store.markers(for: meetingID).isEmpty)

        // Clearing an already-empty meeting is a no-op.
        store.clear(meetingID: meetingID)
        #expect(store.markers(for: meetingID).isEmpty)
    }

    // MARK: - persistence

    @Test func testPersistAcrossInstances() {
        // A new store reading the same defaults sees previously-added markers —
        // the persistence layer is UserDefaults, not in-memory state.
        let meetingID = UUID()
        store.add(meetingID: meetingID, timestamp: 7, label: "Survives a restart")

        let revived = TranscriptMarkerStore(defaults: defaults)
        #expect(revived.markers(for: meetingID).count == 1)
        #expect(revived.markers(for: meetingID).first?.label == "Survives a restart")
    }

    @Test func testLabelStored() {
        let meetingID = UUID()
        store.add(
            meetingID: meetingID,
            timestamp: 88.5,
            label: "Decided on the Q3 roadmap",
            turnIndex: 4)

        let marker = store.markers(for: meetingID).first
        #expect(marker != nil)
        #expect(marker?.label == "Decided on the Q3 roadmap")
        #expect(abs((marker?.timestamp ?? -1) - (88.5)) <= 0.001)
        #expect(marker?.transcriptTurnIndex == 4)
        #expect(marker?.meetingID == meetingID)
    }
}
