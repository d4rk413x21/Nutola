import Foundation

/// File-backed meeting storage. One folder per meeting:
///
///     <root>/Meetings/<uuid>/
///         meeting.json      Meeting
///         transcript.json   [TranscriptSegment]
///         summary.md        markdown
///         notes.md          user scratch notes (during recording)
///         mic.m4a           the user's microphone
///         system.m4a        everyone else (process tap)
///         speaker_events.json  Zoom active-speaker timeline (optional)
///         Edits/             snapshots of summary.md before each overwrite (last N)
///
/// Thread-safe for the app's usage pattern: the UI goes through the
/// @MainActor MeetingStore wrapper; the MCP server process is read-only.
final class MeetingArchive: @unchecked Sendable {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nutola", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "io.github.matheusgois-dd.Nutola.archive")
    // ISO8601 with fractional seconds so Dates round-trip losslessly enough for Equatable.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(MeetingArchive.dateFormatter.string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = MeetingArchive.dateFormatter.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath, debugDescription: "Bad date: \(s)"))
            }
            return date
        }
        return d
    }()

    // MARK: - Transcript decode cache

    /// In-memory cache of decoded transcripts, keyed by meeting id and
    /// validated against the transcript file's mtime. Repeated searches (and
    /// `transcript(for:)` reads) hit this instead of re-decoding thousands of
    /// `TranscriptSegment`s from JSON every time. All access is on `queue`, so
    /// no extra locking is needed; `NSCache` would require bridging value types,
    /// so a plain Dictionary keyed by UUID is simpler and bounded by the number
    /// of meetings (a few hundred at most).
    private var transcriptCache: [UUID: (mtime: Date, segments: [TranscriptSegment])] = [:]

    /// Returns the decoded transcript for `id`, using the in-memory cache when
    /// the on-disk `transcript.json` hasn't changed since the last decode.
    /// Runs on `queue`. Returns `nil` when there's no transcript file.
    private func cachedTranscript(for id: UUID) -> [TranscriptSegment]? {
        let url = folder(for: id).appendingPathComponent("transcript.json")
        guard let mtime = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else {
            transcriptCache.removeValue(forKey: id)
            return nil
        }
        if let cached = transcriptCache[id], cached.mtime == mtime {
            return cached.segments
        }
        guard let data = try? Data(contentsOf: url),
              let segments = try? decoder.decode([TranscriptSegment].self, from: data)
        else {
            transcriptCache.removeValue(forKey: id)
            return nil
        }
        transcriptCache[id] = (mtime, segments)
        return segments
    }

    /// Invalidates the cached transcript for `id` (e.g. after a re-transcribe
    /// or delete). Runs on `queue`.
    private func invalidateTranscriptCache(for id: UUID) {
        transcriptCache.removeValue(forKey: id)
    }

    init(root: URL = MeetingArchive.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
    }

    var meetingsDir: URL { root.appendingPathComponent("Meetings", isDirectory: true) }

    func folder(for id: UUID) -> URL {
        meetingsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func micURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("mic.m4a") }
    func systemURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("system.m4a") }

    // MARK: - Meetings

    func allMeetings() -> [Meeting] {
        queue.sync { decodeMeetingsIn(meetingsDir) }
    }

    /// Async, off-the-caller-thread variant of `allMeetings()`: enumerates the
    /// meetings folder and decodes `meeting.json` on a background priority,
    /// returning via async/await. Callers already on the @MainActor (the UI
    /// reload path) use this so the folder scan + JSON decode never blocks the
    /// main thread. The work still serializes on `queue` for thread-safety with
    /// concurrent writers; only the *await* is suspended off the main thread.
    func allMeetingsAsync() async -> [Meeting] {
        let dir = meetingsDir
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return [] }
            return await withCheckedContinuation { continuation in
                self.queue.async {
                    continuation.resume(returning: self.decodeMeetingsIn(dir))
                }
            }
        }.value
    }

    /// Enumerates `dir` for meeting subfolders and decodes `meeting.json` in
    /// each, newest-first by `createdAt`. Runs on `queue`.
    private func decodeMeetingsIn(_ dir: URL) -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))
            else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func meeting(id: UUID) -> Meeting? {
        queue.sync {
            guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("meeting.json"))
            else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
    }

    enum ArchiveError: Error {
        case meetingDeleted
        case encodingFailed
    }

    /// The meeting folder is created once, at recording start. Refusing to
    /// recreate it here means an in-flight pipeline writing back to a meeting
    /// the user deleted mid-run fails instead of resurrecting it.
    func save(_ meeting: Meeting) throws {
        try queue.sync {
            let dir = folder(for: meeting.id)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                throw ArchiveError.meetingDeleted
            }
            let data = try encoder.encode(meeting)
            try data.write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        }
    }

    func createFolder(for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
    }

    func delete(id: UUID) throws {
        try queue.sync {
            // Idempotent: a double-delete (e.g. user trashed the folder from
            // Finder between the pipeline and a late save) must not throw.
            try? FileManager.default.removeItem(at: folder(for: id))
            invalidateTranscriptCache(for: id)
        }
    }

    // MARK: - Transcript

    func transcript(for id: UUID) -> [TranscriptSegment] {
        queue.sync { cachedTranscript(for: id) ?? [] }
    }

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) throws {
        try queue.sync {
            let data = try encoder.encode(segments)
            try data.write(to: folder(for: id).appendingPathComponent("transcript.json"), options: .atomic)
            invalidateTranscriptCache(for: id)
        }
    }

    // MARK: - Development task drafts

    func developmentTasks(for id: UUID) throws -> DevelopmentTaskReview? {
        try queue.sync {
            let url = folder(for: id).appendingPathComponent("development-tasks.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(DevelopmentTaskReview.self, from: Data(contentsOf: url))
        }
    }

    func saveDevelopmentTasks(_ review: DevelopmentTaskReview, for id: UUID) throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: folder(for: id).appendingPathComponent("meeting.json").path) else {
                throw ArchiveError.meetingDeleted
            }
            try encoder.encode(review).write(
                to: folder(for: id).appendingPathComponent("development-tasks.json"), options: .atomic)
        }
    }


    // MARK: - Live transcript (present only while a meeting is recording)

    func liveTranscriptURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("live.json")
    }

    /// Best-effort atomic write of the rolling transcript. Silently no-ops if the
    /// meeting folder is gone (discarded mid-recording).
    func saveLiveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        queue.sync {
            guard let data = try? encoder.encode(segments) else { return }
            try? data.write(to: liveTranscriptURL(for: id), options: .atomic)
        }
    }

    func liveTranscript(for id: UUID) -> [TranscriptSegment] {
        queue.sync {
            guard let data = try? Data(contentsOf: liveTranscriptURL(for: id)) else { return [] }
            return (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
        }
    }

    /// Last-modified time of the live transcript, for the MCP freshness guard.
    func liveTranscriptModified(for id: UUID) -> Date? {
        queue.sync {
            try? FileManager.default
                .attributesOfItem(atPath: liveTranscriptURL(for: id).path)[.modificationDate] as? Date
        }
    }

    func removeLiveTranscript(for id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: liveTranscriptURL(for: id)) }
    }

    // MARK: - Platform speaker events (Zoom active-speaker timeline)

    func platformSpeakerEventsURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("speaker_events.json")
    }

    func platformSpeakerEvents(for id: UUID) -> [PlatformSpeakerEvent] {
        queue.sync {
            guard let data = try? Data(contentsOf: platformSpeakerEventsURL(for: id)) else { return [] }
            return (try? decoder.decode([PlatformSpeakerEvent].self, from: data)) ?? []
        }
    }

    func savePlatformSpeakerEvents(_ events: [PlatformSpeakerEvent], for id: UUID) {
        queue.sync {
            guard let data = try? encoder.encode(events) else { return }
            try? data.write(to: platformSpeakerEventsURL(for: id), options: .atomic)
        }
    }

    func removePlatformSpeakerEvents(for id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: platformSpeakerEventsURL(for: id)) }
    }

    // MARK: - Zoom roster snapshot (participants panel / video tiles)

    func zoomRosterURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("zoom_roster.json")
    }

    func zoomRoster(for id: UUID) -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: zoomRosterURL(for: id)) else { return [] }
            return (try? decoder.decode([String].self, from: data)) ?? []
        }
    }

    func saveZoomRoster(_ names: [String], for id: UUID) {
        queue.sync {
            do {
                let data = try encoder.encode(names)
                try data.write(to: zoomRosterURL(for: id), options: .atomic)
            } catch {
                NutolaConsoleLog.app("saveZoomRoster: could not persist roster — \(error.localizedDescription)")
            }
        }
    }

    func removeZoomRoster(for id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: zoomRosterURL(for: id)) }
    }

    // MARK: - Summary

    func summary(for id: UUID) -> String {
        queue.sync {
            (try? String(contentsOf: folder(for: id).appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        }
    }

    func saveSummary(_ markdown: String, for id: UUID) throws {
        try queue.sync {
            let summaryURL = folder(for: id).appendingPathComponent("summary.md")
            // Snapshot the outgoing summary so edits are recoverable. Only when a
            // non-empty summary already exists — the first write (empty → content)
            // isn't an edit, and snapshotting it would store an empty file forever.
            if let existing = try? String(contentsOf: summaryURL, encoding: .utf8),
               !existing.isEmpty, existing != markdown {
                snapshotSummary(existing, for: id)
            }
            guard let data = markdown.data(using: .utf8) else { throw ArchiveError.encodingFailed }
            try data.write(to: summaryURL, options: .atomic)
        }
    }

    // MARK: - Summary edit history

    /// Maximum number of summary snapshots kept per meeting. Oldest drop first.
    static let maxSummaryHistory = 20

    private func editsDir(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("Edits", isDirectory: true)
    }

    /// Writes a snapshot of the outgoing summary into `Edits/`, named with a
    /// millisecond-epoch timestamp + a short nonce so multiple edits in the same
    /// millisecond don't collide. Lexicographic filename order == chronological
    /// order, so pruning the oldest is just dropping the first N. Prunes to
    /// `maxSummaryHistory`, oldest first.
    private func snapshotSummary(_ markdown: String, for id: UUID) {
        let dir = editsDir(for: id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NutolaConsoleLog.app("snapshotSummary: could not create Edits dir — \(error.localizedDescription)")
            return
        }
        let epochMS = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = String(UUID().uuidString.prefix(4))
        let name = "summary-\(epochMS)-\(nonce).md"
        let dest = dir.appendingPathComponent(name)
        guard let data = markdown.data(using: .utf8) else {
            NutolaConsoleLog.app("snapshotSummary: could not encode summary as UTF-8")
            return
        }
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            NutolaConsoleLog.app("snapshotSummary: could not write snapshot — \(error.localizedDescription)")
            return
        }
        pruneSummaryHistory(for: id)
    }

    private func pruneSummaryHistory(for id: UUID) {
        let dir = editsDir(for: id)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return }
        guard files.count > Self.maxSummaryHistory else { return }
        for file in files.prefix(files.count - Self.maxSummaryHistory) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// One saved summary snapshot: the timestamp is the write time (from the
    /// filename), `markdown` is the full content of that version.
    struct SummarySnapshot: Equatable, Sendable {
        let timestamp: Date
        let markdown: String
    }
    /// List saved summary snapshots for a meeting, newest first. Empty if the
    /// summary has never been overwritten since first write.
    func summaryHistory(for id: UUID) -> [SummarySnapshot] {
        queue.sync {
            let dir = editsDir(for: id)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" })
            else { return [] }
            // Lexicographic filename order == chronological write order (the
            // epochMS prefix increments; the nonce only breaks ties within a
            // millisecond). Reverse it for newest-first. This is fully
            // deterministic even when two snapshots share the same millisecond,
            // unlike a timestamp-only sort (Swift's sort isn't guaranteed
            // stable for equal keys).
            let chronological = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return chronological.compactMap { file -> SummarySnapshot? in
                let name = file.deletingPathExtension().lastPathComponent
                let withoutPrefix = String(name.dropFirst("summary-".count))
                let parts = withoutPrefix.split(separator: "-")
                guard parts.count >= 2, let epochMS = Int64(parts[0]) else { return nil }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return SummarySnapshot(timestamp: Date(timeIntervalSince1970: TimeInterval(epochMS) / 1000),
                                        markdown: text)
            }
            .reversed() as [SummarySnapshot]
        }
    }

    /// Restore a prior summary snapshot: the current summary becomes a snapshot
    /// itself (so restore is reversible), then the named version is written as
    /// summary.md. Returns true on success.
    @discardableResult
    func restoreSummary(at timestamp: Date, for id: UUID) -> Bool {
        // NOTE: runs entirely inside queue.sync. Do NOT call summaryHistory(for:)
        // here — it also queue.syncs on this serial queue → deadlock. We inline
        // the lookup via the private snapshot reader below.
        queue.sync {
            let dir = editsDir(for: id)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.hasPrefix("summary-") && $0.pathExtension == "md" })
            else { return false }
            let target = files.compactMap { file -> SummarySnapshot? in
                let name = file.deletingPathExtension().lastPathComponent
                let withoutPrefix = String(name.dropFirst("summary-".count))
                let parts = withoutPrefix.split(separator: "-")
                guard parts.count >= 2, let epochMS = Int64(parts[0]) else { return nil }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return SummarySnapshot(timestamp: Date(timeIntervalSince1970: TimeInterval(epochMS) / 1000),
                                        markdown: text)
            }
            .first(where: { $0.timestamp == timestamp })
            guard let target else { return false }
            let summaryURL = folder(for: id).appendingPathComponent("summary.md")
            if let current = try? String(contentsOf: summaryURL, encoding: .utf8),
               !current.isEmpty, current != target.markdown {
                snapshotSummary(current, for: id)
            }
            do {
                try target.markdown.data(using: .utf8)!
                    .write(to: summaryURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Side notes (user scratch pad during recording)

    func sideNotes(for id: UUID) -> String {
        queue.sync {
            (try? String(contentsOf: folder(for: id).appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
        }
    }

    func saveSideNotes(_ text: String, for id: UUID) throws {
        try queue.sync {
            try text.data(using: .utf8)!
                .write(to: folder(for: id).appendingPathComponent("notes.md"), options: .atomic)
        }
    }

    // MARK: - Search

    struct SearchHit: Sendable {
        var meeting: Meeting
        /// Segments (or summary lines) containing the query, capped per meeting.
        var excerpts: [String]
        var score: Int
    }

    /// Case-insensitive multi-word search over titles, summaries, transcripts, attendees.
    ///
    /// Skips the expensive transcript JSON decode when the raw file bytes can't
    /// contain any query word — a cheap `String.contains` pre-filter instead of
    /// decoding thousands of `TranscriptSegment`s for every meeting.
    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let lowerWords = words.map { $0.lowercased() }
        var hits: [SearchHit] = []
        for meeting in allMeetings() {
            var score = 0
            var excerpts: [String] = []
            let title = meeting.title.lowercased()
            for w in lowerWords where title.contains(w) { score += 10 }
            for name in meeting.attendees where lowerWords.contains(where: { name.lowercased().contains($0) }) {
                score += 6
                excerpts.append("Attendee: \(name)")
            }
            let summary = summary(for: meeting.id)
            for line in summary.split(separator: "\n") {
                let lower = line.lowercased()
                if lowerWords.contains(where: { lower.contains($0) }) {
                    score += 3
                    if excerpts.count < 6 { excerpts.append(String(line).trimmingCharacters(in: .whitespaces)) }
                }
            }
            let notes = sideNotes(for: meeting.id)
            for line in notes.split(separator: "\n") {
                let lower = line.lowercased()
                if lowerWords.contains(where: { lower.contains($0) }) {
                    score += 4
                    if excerpts.count < 6 { excerpts.append("Note: \(String(line).trimmingCharacters(in: .whitespaces))") }
                }
            }
            // Pre-filter: skip the transcript decode entirely when the raw file
            // bytes don't contain any query word. Reading the file as a String +
            // lowercasing is far cheaper than decoding thousands of
            // TranscriptSegment objects that would match nothing. When the
            // pre-filter passes, decode via the in-memory cache
            // (`cachedTranscript`) so repeated searches reuse the decoded
            // segments instead of re-parsing the JSON every query.
            let transcriptURL = folder(for: meeting.id).appendingPathComponent("transcript.json")
            if let rawData = try? Data(contentsOf: transcriptURL),
               let rawString = String(data: rawData, encoding: .utf8) {
                let lowerRaw = rawString.lowercased()
                if lowerWords.contains(where: { lowerRaw.contains($0) }) {
                    let speakerNames = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0.name) })
                    let segments = queue.sync { cachedTranscript(for: meeting.id) ?? [] }
                    for seg in segments {
                        let lower = seg.text.lowercased()
                        if lowerWords.contains(where: { lower.contains($0) }) {
                            score += 1
                            if excerpts.count < 6 {
                                let who = speakerNames[seg.speakerID] ?? seg.speakerID
                                excerpts.append("\(who) @ \(Self.timestamp(seg.start)): \(seg.text)")
                            }
                        }
                    }
                }
            }
            if score > 0 { hits.append(SearchHit(meeting: meeting, excerpts: excerpts, score: score)) }
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Cached formatter for elapsed-time "m:ss" timestamps (transcript turn labels,
    /// search excerpts). `.positional` renders minute:second positionally; an empty
    /// `zeroFormattingBehavior` leaves the leading minute unpadded (so "0:05" rather
    /// than "00:05") while the positional style still pads the trailing seconds.
    private static let elapsedFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.zeroFormattingBehavior = []
        f.unitsStyle = .positional
        return f
    }()

    static func timestamp(_ t: TimeInterval) -> String {
        let s = max(Int(t.rounded()), 0)
        let components = DateComponents(minute: s / 60, second: s % 60)
        return elapsedFormatter.string(from: components) ?? "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
