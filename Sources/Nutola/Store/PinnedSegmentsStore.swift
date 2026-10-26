import Foundation
import SwiftUI

/// A bookmarked transcript turn, persisted per meeting in UserDefaults.
/// Carries enough of the turn (speaker + text + timestamp) to render in a
/// pins list without re-reading the transcript.
struct PinnedSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let meetingID: UUID
    let turnID: String
    let speakerID: String
    let text: String
    let timestamp: TimeInterval
    let pinnedAt: Date
}

/// Per-meeting pin storage backed by UserDefaults JSON.
///
/// Each meeting owns a single key, `"pinned-segments-{uuid}"`, holding the
/// encoded `[PinnedSegment]` array. The store is the UI's single source of
/// truth for pin state: it publishes on every mutation so pin buttons and any
/// future pins surface stay in sync without manual refresh.
///
/// UserDefaults is documented thread-safe; mutations are short and
/// non-reentrant, so the store is `@unchecked Sendable` (matching
/// `TemplateStore`) rather than `@MainActor`-isolated.
final class PinnedSegmentsStore: ObservableObject, @unchecked Sendable {
    static let shared = PinnedSegmentsStore()

    private let defaults: UserDefaults
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reads

    /// All pinned turns for a meeting, in the order they were pinned.
    func pins(for meetingID: UUID) -> [PinnedSegment] {
        guard let data = defaults.data(forKey: Self.key(for: meetingID)) else { return [] }
        guard let pins = try? decoder.decode([PinnedSegment].self, from: data) else { return [] }
        return pins
    }

    /// True if `turnID` is pinned for this meeting.
    func isPinned(meetingID: UUID, turnID: String) -> Bool {
        pins(for: meetingID).contains { $0.turnID == turnID }
    }

    // MARK: - Writes

    /// Pin a transcript turn. Idempotent: pinning an already-pinned turn is a
    /// no-op (no duplicate, no timestamp refresh).
    func pin(meetingID: UUID, turn: TranscriptTurn, speakerName: String) {
        var current = pins(for: meetingID)
        guard !current.contains(where: { $0.turnID == turn.id }) else { return }
        current.append(
            PinnedSegment(
                meetingID: meetingID,
                turnID: turn.id,
                speakerID: turn.speakerID,
                text: turn.text,
                timestamp: turn.start,
                pinnedAt: Date()))
        persist(current, for: meetingID)
    }

    /// Remove a pin by turn id. No-op if not pinned.
    func unpin(meetingID: UUID, turnID: String) {
        var current = pins(for: meetingID)
        guard let i = current.firstIndex(where: { $0.turnID == turnID }) else { return }
        current.remove(at: i)
        persist(current, for: meetingID)
    }

    /// Toggle pin state for a turn, returning the new pinned state.
    @discardableResult
    func toggle(meetingID: UUID, turn: TranscriptTurn, speakerName: String) -> Bool {
        if isPinned(meetingID: meetingID, turnID: turn.id) {
            unpin(meetingID: meetingID, turnID: turn.id)
            return false
        } else {
            pin(meetingID: meetingID, turn: turn, speakerName: speakerName)
            return true
        }
    }

    // MARK: - Private

    private func persist(_ pins: [PinnedSegment], for meetingID: UUID) {
        do {
            let data = try encoder.encode(pins)
            defaults.set(data, forKey: Self.key(for: meetingID))
            objectWillChange.send()
        } catch { PersistenceStatus.record(error) }
    }

    static func key(for meetingID: UUID) -> String {
        "pinned-segments-\(meetingID.uuidString)"
    }
}
