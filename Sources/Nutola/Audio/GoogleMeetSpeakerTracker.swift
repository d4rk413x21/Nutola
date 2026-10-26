import Foundation
import Synchronization

/// Caption timestamps are observations, not word alignment; diarization fills the gaps.
struct GoogleMeetTimeline: Sendable {
    private(set) var roomCode: String?
    private(set) var events: [PlatformSpeakerEvent] = []
    private var rows: [String: String] = [:]
    private var suspended = true
    private var active: (name: String, time: TimeInterval)?

    @discardableResult
    mutating func observe(_ snapshot: GoogleMeetSnapshot?, at time: TimeInterval) -> Bool {
        guard let snapshot, roomCode == nil || roomCode == snapshot.roomCode else {
            suspended = true
            active = nil
            return false
        }
        roomCode = snapshot.roomCode
        let current = Dictionary(snapshot.captions.map { ($0.id, $0.name + "\u{0}" + $0.text) },
                                 uniquingKeysWith: { _, latest in latest })
        defer { rows = current; suspended = false }
        // Existing captions can predate recording or belong to the hidden-tab interval.
        guard !suspended else { return true }
        let changed = snapshot.captions.filter {
            rows[$0.id] != current[$0.id] && !rows.values.contains($0.name + "\u{0}" + $0.text)
        }
        let remote = Set(changed.filter { !$0.isLocal }.map(\.name))
        if remote.count == 1, let name = remote.first, time > 0 {
            let event = PlatformSpeakerEvent(name: name, start: max(0, time - 1.5), end: time, source: .caption)
            if let last = events.last, last.name == name, event.start <= last.end + 0.5 {
                events[events.count - 1].end = time
            } else {
                events.append(event)
            }
            active = (name, time)
        } else if !changed.isEmpty || snapshot.captions.isEmpty {
            active = nil
        }
        return true
    }

    func activeName(at time: TimeInterval) -> String? {
        guard let active, time >= active.time, time - active.time <= 2 else { return nil }
        return active.name
    }

    func speaker(at time: TimeInterval) -> String? {
        let names = Set(events.filter { $0.start <= time && time <= $0.end }.map(\.name))
        if names.count == 1 { return names.first }
        if names.count > 1 { return nil }
        return activeName(at: time)
    }
}

final class GoogleMeetSpeakerTracker: PlatformSpeakerTracker {
    @MainActor var onActiveSpeaker: (@MainActor (String?) -> Void)?
    @MainActor var onLocalMuteChanged: (@MainActor (Bool) -> Void)?

    private struct State {
        var timer: (any DispatchSourceTimer)?
        var timeline = GoogleMeetTimeline()
        var participants: [PlatformParticipant] = []
        var lastPersist = Date.distantPast
        var lastReportedName: String?
        var status: String?
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "io.github.d4rk413x21.Nutola.google-meet")
    private let meetingID: UUID
    private let archive: MeetingArchive
    private let startDate: Date
    private let elapsedOffset: TimeInterval

    init(meetingID: UUID, archive: MeetingArchive, startDate: Date, elapsedOffset: TimeInterval) {
        self.meetingID = meetingID
        self.archive = archive
        self.startDate = startDate
        self.elapsedOffset = elapsedOffset
    }

    var statusMessage: String? { state.withLock { $0.status } }
    func currentRoster() -> [String] { state.withLock { $0.participants.map(\.name) } }
    func isLocalParticipant(_ name: String) -> Bool {
        state.withLock { state in
            let matches = state.participants.filter { $0.name == name }
            return !matches.isEmpty && matches.allSatisfy(\.isLocal)
        }
    }
    func speakerAt(_ elapsed: TimeInterval) -> String? { state.withLock { $0.timeline.speaker(at: elapsed) } }

    func start() {
        guard AccessibilityPermission.isTrusted else {
            state.withLock { $0.status = "Optional: enable Nutola in Accessibility settings to identify meeting speakers." }
            return
        }
        state.withLock { state in
            guard state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.tick() }
            state.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            state.withLock { $0.timer?.cancel(); $0.timer = nil }
            persist(force: true)
            Task { @MainActor in self.onActiveSpeaker?(nil) }
        }
    }

    private var now: TimeInterval { elapsedOffset + Date().timeIntervalSince(startDate) }

    private func tick() {
        let room = state.withLock { $0.timeline.roomCode }
        let snapshot = GoogleMeetReader.scan(roomCode: room)
        let time = now
        let change = state.withLock { state -> (Bool, String?) in
            let accepted = state.timeline.observe(snapshot, at: time)
            if accepted, let snapshot {
                if let participants = snapshot.participants { state.participants = participants }
                for caption in snapshot.captions where !caption.isLocal {
                    if !state.participants.contains(where: { $0.name == caption.name }) {
                        state.participants.append(PlatformParticipant(name: caption.name, isLocal: false))
                    }
                }
                state.status = snapshot.captionsEnabled ? nil : "Turn on captions in Google Meet to identify speakers."
            } else {
                state.status = state.timeline.roomCode == nil ? nil
                    : "Keep the recorded Meet meeting selected in Chrome to identify speakers."
            }
            let name = state.timeline.activeName(at: time)
            let changed = name != state.lastReportedName
            state.lastReportedName = name
            return (changed, name)
        }
        if change.0 { Task { @MainActor in self.onActiveSpeaker?(change.1) } }
        persist(force: false)
    }

    private func persist(force: Bool) {
        let snapshot = state.withLock { state -> ([PlatformSpeakerEvent], [PlatformParticipant])? in
            guard state.timeline.roomCode != nil,
                  force || Date().timeIntervalSince(state.lastPersist) >= 2 else { return nil }
            state.lastPersist = Date()
            return (state.timeline.events, state.participants)
        }
        guard let (events, participants) = snapshot else { return }
        archive.savePlatformSpeakerEvents(events, for: meetingID)
        archive.savePlatformParticipants(participants, for: meetingID)
    }
}
