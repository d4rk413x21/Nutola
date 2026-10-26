import Foundation
import Testing
@testable import Nutola

final class PinnedSegmentsTests {
    var defaults: UserDefaults!
    var store: PinnedSegmentsStore!
    private var suite: String!

    init() {
        // A fresh, isolated UserDefaults suite per test so pins never leak
        // across tests or into the host app's .standard defaults.
        suite = "nutola-pins-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = PinnedSegmentsStore(defaults: defaults)
    }

    deinit {
        // Wipe the entire suite so nothing leaks between tests; the suite
        // is unique per test so we can safely remove the whole domain.
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func makeTurn(
        id: String = "me-0",
        speakerID: String = "me",
        start: TimeInterval = 0,
        text: String = "Hello there."
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id, speakerID: speakerID, start: start,
            end: start + 2, text: text, segmentCount: 1)
    }

    @Test func testPinTurn() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Pick this up on Thursday.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")

        let pins = store.pins(for: meetingID)
        #expect(pins.count == 1)
        #expect(pins.first?.turnID == turn.id)
        #expect(pins.first?.text == turn.text)
    }

    @Test func testUnpinTurn() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Action item: ship the build.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        #expect(store.isPinned(meetingID: meetingID, turnID: turn.id))

        store.unpin(meetingID: meetingID, turnID: turn.id)
        #expect(!(store.isPinned(meetingID: meetingID, turnID: turn.id)))
        #expect(store.pins(for: meetingID).isEmpty)
    }

    @Test func testIsPinned() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Worth coming back to.")
        #expect(!(store.isPinned(meetingID: meetingID, turnID: turn.id)))

        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        #expect(store.isPinned(meetingID: meetingID, turnID: turn.id))
    }

    @Test func testMultiplePins() {
        let meetingID = UUID()
        let a = makeTurn(id: "me-0", start: 0, text: "First point.")
        let b = makeTurn(id: "s1-5", speakerID: "s1", start: 5, text: "Second point.")
        let c = makeTurn(id: "me-12", start: 12, text: "Third point.")

        store.pin(meetingID: meetingID, turn: a, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: b, speakerName: "Speaker 1")
        store.pin(meetingID: meetingID, turn: c, speakerName: "Me")

        let pins = store.pins(for: meetingID)
        #expect(pins.count == 3)
        #expect(store.isPinned(meetingID: meetingID, turnID: a.id))
        #expect(store.isPinned(meetingID: meetingID, turnID: b.id))
        #expect(store.isPinned(meetingID: meetingID, turnID: c.id))
    }

    @Test func testPinsForDifferentMeetings() {
        let m1 = UUID()
        let m2 = UUID()
        let turn = makeTurn(text: "Same turn id, different meeting.")

        store.pin(meetingID: m1, turn: turn, speakerName: "Me")
        #expect(store.isPinned(meetingID: m1, turnID: turn.id))
        // The other meeting must not see this pin.
        #expect(!(store.isPinned(meetingID: m2, turnID: turn.id)))
        #expect(store.pins(for: m2).isEmpty)

        // Pinning a different turn under m2 leaves m1 alone.
        let other = makeTurn(id: "s1-3", speakerID: "s1", start: 3, text: "Other meeting.")
        store.pin(meetingID: m2, turn: other, speakerName: "Speaker 1")
        #expect(store.pins(for: m1).count == 1)
        #expect(store.pins(for: m2).count == 1)
        #expect(store.pins(for: m2).first?.turnID == other.id)
    }

    @Test func testPinTextAndSpeakerStored() {
        let meetingID = UUID()
        let turn = makeTurn(
            id: "s2-42", speakerID: "s2", start: 42.5,
            text: "Let's circle back to the pricing model.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Jordan")

        let pin = store.pins(for: meetingID).first
        #expect(pin != nil)
        #expect(pin?.meetingID == meetingID)
        #expect(pin?.turnID == "s2-42")
        #expect(pin?.speakerID == "s2")
        #expect(pin?.text == "Let's circle back to the pricing model.")
        #expect(abs((pin?.timestamp ?? -1) - (42.5)) <= 0.001)
        // speakerName is a UI convenience for rendering, not persisted on the pin.
        #expect(pin?.pinnedAt != nil)
    }

    @Test func testPinIsIdempotent() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Pin me twice, expect one pin.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        #expect(store.pins(for: meetingID).count == 1)
    }

    @Test func testToggleFlipsPinState() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Toggle me.")

        let pinned = store.toggle(meetingID: meetingID, turn: turn, speakerName: "Me")
        #expect(pinned)
        #expect(store.isPinned(meetingID: meetingID, turnID: turn.id))

        let unpinned = store.toggle(meetingID: meetingID, turn: turn, speakerName: "Me")
        #expect(!(unpinned))
        #expect(!(store.isPinned(meetingID: meetingID, turnID: turn.id)))
    }

    @Test func testUnpinNotPinnedIsNoOp() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Never pinned.")
        store.unpin(meetingID: meetingID, turnID: turn.id) // should not throw / mutate
        #expect(store.pins(for: meetingID).isEmpty)
    }

    @Test func testPinsReturnInInsertionOrder() {
        let meetingID = UUID()
        let a = makeTurn(id: "me-0", start: 0, text: "First pinned.")
        let b = makeTurn(id: "me-5", start: 5, text: "Second pinned.")
        let c = makeTurn(id: "me-9", start: 9, text: "Third pinned.")

        store.pin(meetingID: meetingID, turn: a, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: b, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: c, speakerName: "Me")

        let pins = store.pins(for: meetingID)
        #expect(pins.count == 3)
        // Pins come back in the order they were added, oldest first.
        #expect(pins.map(\.turnID) == ["me-0", "me-5", "me-9"], "insertion order preserved")
    }

    @Test func testPersistAcrossStoreInstances() {
        // A new store reading the same defaults sees previously-pinned turns —
        // the persistence layer is UserDefaults, not in-memory state.
        let meetingID = UUID()
        let turn = makeTurn(text: "Survives a restart.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")

        let revived = PinnedSegmentsStore(defaults: defaults)
        #expect(revived.pins(for: meetingID).count == 1)
        #expect(revived.pins(for: meetingID).first?.turnID == turn.id)
    }
}
