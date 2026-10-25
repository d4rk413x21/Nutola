import Foundation
import Synchronization
import AppKit
import ApplicationServices

/// Polls the installed Zoom Workplace client during recording and logs who the
/// meeting UI marks as speaking. Events are written to `speaker_events.json`
/// and later correlated with the system-audio transcript.
final class ZoomSpeakerTracker: PlatformSpeakerTracker, @unchecked Sendable {
    private let meetingID: UUID
    private let archive: MeetingArchive
    private let startDate: Date
    private let elapsedOffset: TimeInterval
    private let queue = DispatchQueue(label: "io.github.d4rk413x21.Nutola.zoom-speakers")
    /// Interval between active-speaker polls (seconds). 400 ms balances responsiveness
    /// against AX-tree traversal cost on long calls.
    private static let zoomPollInterval: TimeInterval = 0.4
    /// Delay before the first poll after `start()` (seconds), letting Zoom settle.
    private static let zoomPollStartupDelay: TimeInterval = 0.5
    /// Shared locale-aware formatter for second values in log strings, replacing
    /// `String(format: "%.1f"/"%.0f", …)` which ignores the user's locale.
    private static let secondsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()
    /// Formats `t` seconds with one decimal, locale-aware.
    private static func seconds(_ t: TimeInterval) -> String {
        secondsFormatter.string(from: NSNumber(value: t)) ?? "\(t)"
    }
    private static let secondsRoundedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 0
        f.roundingMode = .halfEven
        return f
    }()
    /// Formats `t` seconds with no decimals, locale-aware.
    private static func secondsRounded(_ t: TimeInterval) -> String {
        secondsRoundedFormatter.string(from: NSNumber(value: t)) ?? "\(Int(t))"
    }
    private var timer: DispatchSourceTimer?
    private var events: [PlatformSpeakerEvent] = []
    private var open: (name: String, start: TimeInterval, source: PlatformSpeakerSource)?
    private var lastPersist = Date.distantPast
    private var lastReportedName: String?
    private var tickCount = 0
    /// Count of consecutive ticks with no active speaker; surfaced in the periodic
    /// heartbeat log so a stuck/empty-scan state is visible without a separate probe.
    private var emptyTickStreak = 0
    private var lastSummary = Date.distantPast
    private var lastCaptionKey: String?
    private var lastRoster: [String] = []
    private var rosterPersisted = false
    private var lastLocalMuted: Bool?
    /// One-shot: dump the AX tree once when active speaker detection fails for
    /// several consecutive ticks despite having a roster. `logInitialScan` only
    /// fires at start(); if the meeting starts after Nutola launches, we'd never
    /// get a dump. This fires mid-meeting the first time emptyStreak hits 10.
    private var dumpedForEmptyActive = false

    /// Called on the main queue when the local participant's Zoom mute state changes.
    /// True = muted in Zoom (don't capture mic), false = unmuted (capture mic).
    @MainActor var onLocalMuteChanged: (@MainActor (Bool) -> Void)?

     /// Called on the main queue whenever the active remote speaker changes.
     @MainActor var onActiveSpeaker: (@MainActor (String?) -> Void)?
    /// Thread-safe snapshot of the active speaker name at a given elapsed time.
    /// Called from the LiveTranscriber's handle() to attribute system-audio
    /// segments to the Zoom-reported speaker instead of generic "Others".
    func speakerAt(_ t: TimeInterval) -> String? {
        queue.sync {
            // Check the open segment first (most recent), then walk events backward.
            if let open, t >= open.start {
                return open.name
            }
            for event in events.reversed() where t >= event.start && t < event.end {
                return event.name
            }
            return nil
        }
    }

    /// Thread-safe snapshot of the current participant roster.
    func currentRoster() -> [String] {
        queue.sync { lastRoster }
    }

    init(
        meetingID: UUID,
        archive: MeetingArchive,
        startDate: Date,
        elapsedOffset: TimeInterval = 0
    ) {
        self.meetingID = meetingID
        self.archive = archive
        self.startDate = startDate
        self.elapsedOffset = elapsedOffset
    }

    func start() {
        let trusted = AccessibilityPermission.isTrusted
        NutolaConsoleLog.zoom(
            "start meeting=\(meetingID.uuidString.prefix(8)) accessibility=\(trusted)")
        guard trusted else {
            NutolaConsoleLog.zoom("blocked — grant Accessibility to Nutola, then refocus the app")
            Task { @MainActor in AccessibilityPermission.request() }
            return
        }
        queue.async {
            guard self.timer == nil else {
                NutolaConsoleLog.zoom("start skipped — timer already running")
                return
            }
            NutolaConsoleLog.zoom("polling every \(Int(Self.zoomPollInterval * 1000))ms")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.zoomPollStartupDelay, repeating: Self.zoomPollInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            self.logInitialScan()
        }
    }

    func stop() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.closeOpen(until: self.now)
            self.persist(force: true)
            // Always persist the final roster so the batch pipeline can attribute
            // speaker names even if the roster never changed during the call
            // (the tick() save is gated on roster change, which never fires for
            // a stable participant list — leaving no zoom_roster.json behind).
            if !self.lastRoster.isEmpty {
                self.archive.saveZoomRoster(self.lastRoster, for: self.meetingID)
                NutolaConsoleLog.zoom("stop: persisted final roster (\(self.lastRoster.count) names)")
            }
            let saved = PlatformSpeakerTurnBuilder.normalized(self.events)
            NutolaConsoleLog.zoom(
                "stop ticks=\(self.tickCount) events=\(saved.count) saved=\(saved.map { "\($0.name) \(Self.seconds($0.start))-\(Self.seconds($0.end))" }.joined(separator: ", "))")
            Task { @MainActor in self.onActiveSpeaker?(nil) }
        }
    }

    // MARK: - Internals

    private func logInitialScan() {
        let scan = ZoomActiveSpeakerReader.scan()
        NutolaConsoleLog.zoom(
            "initial scan zoomPID=\(scan.zoomPID.map(String.init) ?? "nil") roster=[\(scan.roster.joined(separator: ", "))] active=[\(scan.active.joined(separator: ", "))] captions=\(scan.latestCaption.map { "\($0.name): \($0.text.prefix(40))" } ?? "none")")
        // Full AX tree dump for debugging — reveals tile descriptions, roles, and
        // attributes the parsers might miss. Logged at .info so it appears in Console.app.
        if scan.roster.isEmpty || (scan.active.isEmpty && !scan.roster.isEmpty) {
            NutolaConsoleLog.zoom("no active speaker found (roster=\(scan.roster.count)) — dumping full AX tree for diagnosis")
            ZoomActiveSpeakerReader.dumpAXTree()
        }
    }

    private func tick() {
        tickCount += 1
        let scan = ZoomActiveSpeakerReader.scan()
        let names = scan.active
        let t = now

        recordCaption(scan.latestCaption, at: t)

        if names.isEmpty {
            emptyTickStreak += 1
            closeOpen(until: t)
            reportActive(nil)
        } else {
            emptyTickStreak = 0
            let primary = names[0]
            let source = scan.activeSource
            reportActive(primary)
            if let open, open.name != primary {
                events.append(PlatformSpeakerEvent(
                    name: open.name, start: open.start, end: t, source: open.source))
                NutolaConsoleLog.zoom(
                    "segment closed \(open.name) \(Self.seconds(open.start))-\(Self.seconds(t))s → now \(primary)")
                self.open = (primary, t, source)
            } else if open == nil {
                open = (primary, t, source)
                NutolaConsoleLog.zoom("segment opened \(primary) @ \(Self.seconds(t))s (\(source.rawValue))")
            }
            persist(force: false)
        }

        // Persist the roster whenever it changes, OR on the first non-empty scan.
        // When the scan returns empty (Zoom window temporarily not in the AX tree,
        // e.g. another app frontmost, window redrawing), keep the last known roster
        // rather than blanking it — the participants haven't actually left.
        if scan.roster.isEmpty {
            // Keep lastRoster; don't overwrite with empty.
        } else if scan.roster != lastRoster || !rosterPersisted {
            lastRoster = scan.roster
            archive.saveZoomRoster(scan.roster, for: meetingID)
            rosterPersisted = true
        }

        // Detect local participant's mute state change. When muted in Zoom,
        // the mic should stop capturing (silence anyway) and live segments
        // should not be attributed to "me". When unmuted, resume capturing.
        if let muted = scan.localParticipantMuted, muted != lastLocalMuted {
            lastLocalMuted = muted
            NutolaConsoleLog.zoom("local participant \(muted ? "muted" : "unmuted") — \(muted ? "pausing mic capture" : "resuming mic capture")")
            DispatchQueue.main.async { self.onLocalMuteChanged?(muted) }
        }

        let now = Date()
        if now.timeIntervalSince(lastSummary) >= 5 {
            lastSummary = now
            NutolaConsoleLog.zoom(
                "heartbeat ticks=\(tickCount) active=\(names.first ?? "none")\(names.count > 1 ? " all=[\(names.joined(separator: ", "))]" : "") roster=\(scan.roster.count) emptyStreak=\(emptyTickStreak) events=\(events.count) elapsed=\(Self.secondsRounded(t))s")
            if names.isEmpty, !scan.roster.isEmpty {
                NutolaConsoleLog.zoom(
                    "no active speaker tile — roster: [\(scan.roster.joined(separator: ", "))]")
            }
            if scan.roster.isEmpty {
                NutolaConsoleLog.zoom(
                    "no participant tiles found — is Zoom in a meeting? pid=\(scan.zoomPID.map(String.init) ?? "nil")")
            }
        }
        // One-shot mid-meeting diagnostic dump: if we've had 10+ consecutive
        // ticks with no active speaker but a populated roster, dump the AX tree
        // once so we can see what attributes Zoom exposes for the active speaker.
        // logInitialScan only fires at start(); this catches meetings that begin
        // after Nutola launches.
        if !dumpedForEmptyActive, emptyTickStreak >= 10, !scan.roster.isEmpty {
            dumpedForEmptyActive = true
            NutolaConsoleLog.zoom("emptyStreak=\(emptyTickStreak) with roster=\(scan.roster.count) — dumping AX tree for active-speaker diagnosis")
            ZoomActiveSpeakerReader.dumpAXTree()
        }
    }

    private func reportActive(_ name: String?) {
        let previous = lastReportedName
        guard name != previous else { return }
        lastReportedName = name
        if let name {
            NutolaConsoleLog.zoom("active speaker → \(name)")
        } else if previous != nil {
            NutolaConsoleLog.zoom("active speaker cleared")
        }
        Task { @MainActor in onActiveSpeaker?(name) }
    }

    private func closeOpen(until end: TimeInterval) {
        guard let open else { return }
        if end > open.start {
            events.append(PlatformSpeakerEvent(
                name: open.name, start: open.start, end: end, source: open.source))
        }
        self.open = nil
    }

    /// Captures a short caption window when Zoom live transcript exposes speaker-prefixed lines.
    private func recordCaption(_ caption: ZoomActiveSpeakerReader.CaptionLine?, at t: TimeInterval) {
        guard let caption else { return }
        let key = "\(caption.name)|\(caption.text)"
        guard key != lastCaptionKey else { return }
        lastCaptionKey = key
        let start = max(0, t - 1.5)
        events.append(PlatformSpeakerEvent(
            name: caption.name, start: start, end: t, source: .caption))
        NutolaConsoleLog.zoom("caption \(caption.name): \(caption.text.prefix(60))")
        persist(force: false)
    }

    private var now: TimeInterval {
        elapsedOffset + Date().timeIntervalSince(startDate)
    }

    private func persist(force: Bool) {
        let current = Date()
        guard force || current.timeIntervalSince(lastPersist) >= 2 else { return }
        lastPersist = current
        let normalized = PlatformSpeakerTurnBuilder.normalized(events)
        archive.savePlatformSpeakerEvents(normalized, for: meetingID)
        if force || normalized.count % 3 == 0 {
            NutolaConsoleLog.zoom("persisted \(normalized.count) events to speaker_events.json")
        }
    }
}

// MARK: - Zoom AX reader

enum ZoomActiveSpeakerReader {
    struct CaptionLine: Sendable, Equatable {
        var name: String
        var text: String
    }

    struct ScanResult: Sendable {
        var zoomPID: pid_t?
        var roster: [String]
        var active: [String]
        var activeSource: PlatformSpeakerSource
        var latestCaption: CaptionLine?
        /// True when the local participant's Zoom tile says "Computer audio muted".
        /// Nil when the local participant's tile wasn't found in this scan.
        var localParticipantMuted: Bool?
    }

    private static let mainBundleID = "us.zoom.xos"

    private static let ignoredExact: Set<String> = [
        "zoom", "zoom workplace", "zoom meeting", "zoom webinar",
        "mute", "unmute", "mute audio", "unmute audio", "mute my audio",
        "start video", "stop video", "participants", "chat", "share screen",
        "share", "reactions", "security", "polls", "breakout rooms", "more",
        "leave", "end", "end meeting", "leave meeting", "raise hand",
        "lower hand", "closed caption", "live transcript", "view", "record",
        "apps", "whiteboards", "you", "me", "host", "co-host", "guest",
    ]

    /// Cached AX-tree signature + result so a steady-state Zoom UI (no tile
    /// added/removed, no speaker transition) skips the full recursive `walk`
    /// and returns the last `ScanResult` directly. The signature captures role,
    /// child count, and title/description of every node (bounded depth), so any
    /// speaker transition or roster change alters it and forces a fresh scan.
    private struct ScanCache {
        var signature: Int?
        var result: ScanResult?
    }
    private static let scanCache = Mutex(ScanCache())

    static func scan() -> ScanResult {
        scanCache.withLock { cache in
            guard AccessibilityPermission.isTrusted else {
                cache.signature = nil
                cache.result = nil
                return ScanResult(
                    zoomPID: nil, roster: [], active: [], activeSource: .activeSpeaker,
                    latestCaption: nil, localParticipantMuted: nil)
            }
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == mainBundleID
            }) else {
                cache.signature = nil
                cache.result = nil
                return ScanResult(
                    zoomPID: nil, roster: [], active: [], activeSource: .activeSpeaker,
                    latestCaption: nil, localParticipantMuted: nil)
            }

            let root = AXUIElementCreateApplication(app.processIdentifier)
            // Build the entry-point windows the same way the full scan would, then
            // hash their subtree shape. A matching signature means the tree is
            // unchanged since the last poll → return the cached result and skip the
            // expensive walk + per-node regex parsing.
            var scannedWindows = allWindows(root)
            if scannedWindows.isEmpty {
                if let focused = focusedWindow(root) {
                    scannedWindows = [focused]
                }
            }
            // No window accessible at all — Zoom is on another Space, minimized, or
            // its window is mid-redraw. Walking root yields only the menu bar (an
            // empty roster), and caching that would blank the UI on every transient
            // AX failure. Instead, keep the last known non-empty result so the
            // roster and active-speaker timeline stay stable until the window
            // reappears. If there's no prior result, fall through to the root walk
            // so the first scan still runs (and logs/dumps for diagnosis).
            if scannedWindows.isEmpty, let cached = cache.result, !cached.roster.isEmpty {
                return cached
            }
            let signature = treeSignature(of: scannedWindows, fallback: root)
            // Bypass the cache when we have participants but no active speaker.
            // The signature hashes role/title/description/childCount — NOT AXValue
            // or AXSelected. If Zoom indicates the active speaker via a mechanism
            // other than the tile description (AXValue, a child element, visual
            // highlight), the signature stays stable across speaker transitions and
            // the cache would return the same empty-active result forever. Forcing
            // a fresh walk every tick ensures any new parser logic actually runs.
            if signature == cache.signature, let cached = cache.result,
               !(cached.active.isEmpty && !cached.roster.isEmpty) {
                return cached
            }

            var roster: [String] = []

            var activeTiles: [String] = []
            var activeLabels: [String] = []
            var selectedTiles: [String] = []
            var latestCaption: CaptionLine?
            var localMuted: Bool?
            // Strategy: try multiple AX entry points to find participant tiles.
            // 1. kAXWindowsAttribute — all windows (works when on the active Space).
            // 2. kAXFocusedWindowAttribute — the focused window (works even when on
            //    another Space — kAXWindowsAttribute returns 0 for inactive Spaces,
            //    but the focused window is still accessible with its full subtree).
            // 3. kAXChildrenAttribute on root — last resort (usually just the menu bar).
            if scannedWindows.isEmpty {
                walk(
                    root, depth: 0, roster: &roster,
                    activeTiles: &activeTiles, activeLabels: &activeLabels,
                    selectedTiles: &selectedTiles, latestCaption: &latestCaption,
                    localMuted: &localMuted)
            } else {
                for window in scannedWindows {
                    walk(
                        window, depth: 0, roster: &roster,
                        activeTiles: &activeTiles, activeLabels: &activeLabels,
                        selectedTiles: &selectedTiles, latestCaption: &latestCaption,
                        localMuted: &localMuted)
                }
            }
            let rosterOut = deduped(roster)
            // Gallery tiles list every unmuted participant; only trust explicit
            // "active speaker" markers on those tiles. Legacy labels (participants
            // panel, notifications) are a fallback when no tile is marked.
            let (activeOut, source): ([String], PlatformSpeakerSource)
            if !activeTiles.isEmpty {
                activeOut = activeTiles
                source = .activeSpeaker
            } else if !activeLabels.isEmpty {
                activeOut = activeLabels
                source = .activeSpeaker
            } else {
                activeOut = selectedTiles
                source = .selectedTile
            }
            // Validate the caption against the roster when we have one: Zoom's
            // live-transcript lines name actual participants, so a parsed "name"
            // that isn't close to anyone on the roster is a false positive — usually
            // a window title or tab label that happened to contain a colon. When
            // the roster is empty (meeting just started, or AX couldn't read tiles),
            // fall back to a name-shape heuristic so junk like "Backend Monorepo
            // DevX" doesn't sneak in as a speaker.
            let validatedCaption = latestCaption.flatMap { caption -> CaptionLine? in
                if !rosterOut.isEmpty {
                    return nameMatchesRoster(caption.name, rosterOut) ? caption : nil
                }
                return looksLikePersonName(caption.name) ? caption : nil
            }
            let result = ScanResult(
                zoomPID: app.processIdentifier,
                roster: rosterOut,
                active: deduped(activeOut).filter { !isLocalParticipant($0) },
                activeSource: source,
                latestCaption: validatedCaption,
                localParticipantMuted: localMuted)
            cache.signature = signature
            cache.result = result
            return result
        }
    }

    /// Cheap structural fingerprint of the Zoom AX subtree rooted at `windows`
    /// (or `fallback` when there are no windows). Hashes role, child count, and
    /// the title/description of each node up to a bounded depth — enough that any
    /// speaker transition (tile gains/loses "active speaker") or roster change
    /// (tile added/removed) perturbs it, while reading far fewer AX attributes
    /// than the full `walk()` (which also parses value/selected + runs regexes).
    private static func treeSignature(of windows: [AXUIElement], fallback: AXUIElement) -> Int {
        var hasher = Hasher()
        if windows.isEmpty {
            hashSubtree(fallback, depth: 0, into: &hasher)
        } else {
            for window in windows {
                hashSubtree(window, depth: 0, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    private static func hashSubtree(_ element: AXUIElement, depth: Int, into hasher: inout Hasher) {
        guard depth < 20 else { return }
        hasher.combine(role(element))
        hasher.combine(attribute(element, kAXTitleAttribute as CFString) ?? "")
        hasher.combine(attribute(element, kAXDescriptionAttribute as CFString) ?? "")
        let kids = children(element)
        hasher.combine(kids.count)
        for child in kids {
            hashSubtree(child, depth: depth + 1, into: &hasher)
        }
    }

    /// Diagnostic: dumps the full Zoom AX tree (first ~500 elements) to the unified
    /// log. Run at recording start and on demand to debug why speaker names aren't
    /// being detected — reveals tile descriptions, roles, and attributes that the
    /// parsers might be missing.
    static func dumpAXTree() {
        guard AccessibilityPermission.isTrusted else {
            NutolaConsoleLog.zoom("dumpAXTree — no Accessibility permission")
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == mainBundleID
        }) else {
            NutolaConsoleLog.zoom("dumpAXTree — Zoom not running")
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var count = 0
        let maxDump = 500
        func dump(_ element: AXUIElement, depth: Int) {
            guard count < maxDump else { return }
            let r = role(element)
            let desc = attribute(element, kAXDescriptionAttribute as CFString) ?? ""
            let title = attribute(element, kAXTitleAttribute as CFString) ?? ""
            let val = attribute(element, kAXValueAttribute as CFString) ?? ""
            let sel = isSelected(element)
            let ident = attribute(element, kAXIdentifierAttribute as CFString) ?? ""
            let indent = String(repeating: "  ", count: min(depth, 10))
            if !desc.isEmpty || !title.isEmpty || !val.isEmpty || !ident.isEmpty || r != "AXUnknown" {
                var parts = ["role=\(r)"]
                if !desc.isEmpty { parts.append("desc=\(desc.prefix(120))") }
                if !title.isEmpty { parts.append("title=\(title.prefix(80))") }
                if !val.isEmpty { parts.append("val=\(val.prefix(80))") }
                if !ident.isEmpty { parts.append("id=\(ident.prefix(60))") }
                if sel { parts.append("SELECTED") }
                NutolaConsoleLog.zoom("AX[\(count)] \(indent)\(parts.joined(separator: " "))")
                count += 1
            }
            for child in children(element) {
                dump(child, depth: depth + 1)
                if count >= maxDump { break }
            }
        }
        NutolaConsoleLog.zoom("=== Zoom AX Tree Dump (pid=\(app.processIdentifier)) ===")
        let windows = allWindows(root)
        if windows.isEmpty {
            dump(root, depth: 0)
        } else {
            NutolaConsoleLog.zoom("(\(windows.count) windows found via kAXWindowsAttribute)")
            for window in windows {
                dump(window, depth: 0)
                if count >= maxDump { break }
            }
        }
        NutolaConsoleLog.zoom("=== AX Tree Dump: \(count) elements ===")
    }

    /// True when Zoom's display name matches the Mac account holder (local mic).
    static func isLocalParticipant(_ name: String) -> Bool {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return false }
        let nameL = name.lowercased()
        let fullL = full.lowercased()
        if nameL == fullL { return true }
        let nameParts = nameL.split(separator: " ")
        let fullParts = Set(fullL.split(separator: " "))
        guard !nameParts.isEmpty else { return false }
        return nameParts.allSatisfy { fullParts.contains($0) }
    }
    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        roster: inout [String],
        activeTiles: inout [String],
        activeLabels: inout [String],
        selectedTiles: inout [String],
        latestCaption: inout CaptionLine?,
        localMuted: inout Bool?
    ) {
        guard depth < 20 else { return }

        let r = role(element)
        if r == "AXTabGroup" || r == "AXGroup" {
            if let desc = attribute(element, kAXDescriptionAttribute as CFString) {
                if let name = parseZoomParticipantDescription(desc) {
                    roster.append(name)
                    if isSelected(element) {
                        selectedTiles.append(name)
                    }
                    // Detect the local participant's mute state from the tile
                    // description: "Name, Computer audio muted/unmuted, Video on/off".
                    if localMuted == nil, isLocalParticipant(name) {
                        let lower = desc.lowercased()
                        if lower.contains("computer audio muted") {
                            localMuted = true
                        } else if lower.contains("computer audio unmuted") {
                            localMuted = false
                        }
                    }
                }
                if let name = parseZoomTileDescription(desc) {
                    activeTiles.append(name)
                }
            }
            // Zoom may indicate the active speaker via AXValue instead of (or in
            // addition to) AXDescription — some view modes put the speaking
            // marker there. Check it as a fallback for active-speaker detection.
            if let val = attribute(element, kAXValueAttribute as CFString) {
                if let name = parseZoomTileDescription(val) {
                    activeTiles.append(name)
                }
            }
        }

        if r == "AXRow" || r == "AXOutlineRow" || r == "AXCell" {
            for key in [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
                        kAXValueAttribute as CFString] {
                if let text = attribute(element, key), let name = parseParticipantRow(text) {
                    roster.append(name)
                }
            }
        }

        for text in [attribute(element, kAXDescriptionAttribute as CFString),
                     attribute(element, kAXTitleAttribute as CFString),
                     attribute(element, kAXValueAttribute as CFString)].compactMap({ $0 }) {
            guard !isParticipantTileDescription(text) else { continue }
            if let name = parseSpeakingLabel(text) {
                activeLabels.append(name)
            }
            if let caption = parseZoomCaptionLine(text) {
                latestCaption = caption
            }
        }

        for child in children(element) {
            walk(
                child, depth: depth + 1, roster: &roster,
                activeTiles: &activeTiles, activeLabels: &activeLabels,
                selectedTiles: &selectedTiles, latestCaption: &latestCaption,
                localMuted: &localMuted)
        }
    }

    /// Zoom video tiles embed mic/video state — not a speaking indicator.
    private static func isParticipantTileDescription(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("computer audio") || lower.contains("video on") || lower.contains("video off")
    }

    /// Any video tile: `"Gui Lima, Computer audio unmuted, Video on"`.
    static func parseZoomParticipantDescription(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("computer audio") || lower.contains("video on") else { return nil }
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        return cleaned(String(raw[..<comma]))
    }

    /// Active speaker tile: `"Gui Lima, Computer audio unmuted, Video on, active speaker"`.
    static func parseZoomTileDescription(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("active speaker") else { return nil }
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        return cleaned(String(raw[..<comma]))
    }

    /// Parses legacy/alternate Zoom UI strings like `"Jimmy Veloso, unmuted"`.
    static func parseSpeakingLabel(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for regex in speakingLabelRegexes {
            if let name = firstCapture(regex: regex, in: text) {
                return cleaned(name)
            }
        }
        return nil
    }

    /// Zoom live-transcript / closed-caption lines: `"Gui Lima: hello everyone"`.
    static func parseZoomCaptionLine(_ raw: String) -> CaptionLine? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for regex in captionLineRegexes {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 2,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[nameRange])
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 2,
                  let cleanedName = cleaned(name),
                  !isParticipantTileDescription(text) else { continue }
            return CaptionLine(name: cleanedName, text: body)
        }
        return nil
    }


    /// Participants panel rows — plain display names without tile metadata.
    static func parseParticipantRow(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("computer audio") || lower.contains("video on") || lower.contains("active speaker") {
            return nil
        }
        if lower.contains("participant") || lower.contains("meeting") || lower.contains("mute") {
            return nil
        }
        // Chat-panel context lines leak through as AXRow/AXCell children:
        // "Reply to Victor Moura de Britto", "Reply to Gui Lima". These are
        // reply affordances, not participant names.
        if lower.hasPrefix("reply to") {
            return nil
        }
        // Zoom Phone call-history rows leak through when the Phone tab is open
        // instead of a meeting: "+ 5 5 1 1 9 8 4 6 9...", "DoorDash", phone
        // numbers, "Incoming"/"Outgoing"/"Canceled"/"Missed" call labels.
        // Reject entries containing phone-number patterns (digits separated by
        // spaces), call-direction keywords, or known org names from call logs.
        if lower.contains("incoming") || lower.contains("outgoing") ||
            lower.contains("canceled") || lower.contains("missed call") ||
            lower.contains("voicemail") {
            return nil
        }
        // Phone numbers: "+ 5 5 1 1 ..." or "(555) 123-4567" or "555-123-4567".
        // Match digit-heavy strings with separators (phone format), or entries
        // starting with "+".
        if text.hasPrefix("+") { return nil }
        let digitCount = text.filter(\.isNumber).count
        let letterCount = text.filter(\.isLetter).count
        if digitCount >= 7 && digitCount > letterCount { return nil }
        // Call-log entries often have multiple consecutive commas:
        // "Gui Lima, Outgoing, 2:30 PM, 5 min". Meeting participant rows are a
        // single display name with no comma-separated fields.
        let commaCount = text.filter { $0 == "," }.count
        if commaCount >= 2 { return nil }
        // Zoom Phone call history can surface company/organization names that
        // are never meeting participants (e.g. "DoorDash" from call logs).
        // These pass the call-direction and digit filters, so reject them here.
        let nonParticipantNames: Set<String> = ["doordash"]
        if nonParticipantNames.contains(lower) { return nil }
        return cleaned(text)
    }

    private static func isSelected(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) == true
    }

    /// Compiled once at type load and reused across every poll (was rebuilt on
    /// every call — the AX tree fires this hundreds of times per minute).
    private static let speakingLabelRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^(.+?),\s*unmuted(?:\s+audio)?$"#,
            #"^(.+?)\s+is\s+speaking$"#,
            #"^(.+?)\s+is\s+talking$"#,
            #"^speaking:\s*(.+)$"#,
            #"^active\s+speaker:\s*(.+)$"#,
            #"^(.+?),\s*speaking$"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// Caption-line patterns for `parseZoomCaptionLine`, compiled once at load.
    private static let captionLineRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^(.+?)\s+said:\s+(.+)$"#,
            #"^(.+?):\s+(.+)$"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    private static func firstCapture(regex: NSRegularExpression, in original: String) -> String? {
        let range = NSRange(original.startIndex..<original.endIndex, in: original)
        guard let match = regex.firstMatch(in: original, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: original) else { return nil }
        return String(original[capture])
    }

    /// True when `name` matches (or closely resembles) an entry in `roster`.
    /// Used to filter caption false positives: Zoom's live-transcript lines
    /// always name an actual participant, so a parsed "name" that isn't close
    /// to anyone on the roster is a window title or tab label, not a speaker.
    private static func nameMatchesRoster(_ name: String, _ roster: [String]) -> Bool {
        let n = name.lowercased()
        for r in roster {
            let rL = r.lowercased()
            if n == rL { return true }
            if n.hasPrefix(rL) || rL.hasPrefix(n) { return true }
            // Match on last name when the roster entry has multiple tokens
            // ("David Cleckley" ↔ "David", "Cleckley", "David C.").
            let rTokens = rL.split(separator: " ").map(String.init)
            let nTokens = n.split(separator: " ").map(String.init)
            if let last = rTokens.last, nTokens.contains(last) { return true }
            if let last = nTokens.last, rTokens.contains(last) { return true }
        }
        return false
    }

    /// Heuristic used when no roster is available: does `name` look like a real
    /// person's name rather than a window/tab title or a technical phrase?
    /// Rejects multi-word names containing technical/organizational terms
    /// ("Backend Monorepo DevX", "Identity Intelligence Engineering") and
    /// names that are too long or all-lowercase. Keeps it conservative — when
    //  in doubt, reject: a dropped caption is far less damaging than a wrong
    //  speaker name polluting the transcript attribution.
    private static let technicalNameTerms: Set<String> = [
        "monorepo", "devx", "backend", "frontend", "repository", "infra",
        "pipeline", "dashboard", "service", "sdk", "api", "webhook",
        "intelligence", "engineering", "platform", "portal", "webview",
        "coordination", "protocol", "mitigation", "invalidation",
    ]

    private static func looksLikePersonName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 60 else { return false }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard tokens.count <= 4 else { return false }
        // Multi-word names containing a technical term are almost always
        // window/tab titles ("Backend Monorepo DevX"), not people.
        for token in tokens {
            if technicalNameTerms.contains(token.lowercased()) { return false }
        }
        // Each token should be capitalized (a person's name) — reject
        // all-lowercase or all-uppercase strings, which are usually code
        // identifiers or constants.
        for token in tokens {
            guard let first = token.first, first.isLetter, first.isUppercase || token.count == 1 else {
                return false
            }
        }
        return true
    }

    private static func cleaned(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard name.count >= 2, name.count <= 80 else { return nil }
        let lower = name.lowercased()
        if ignoredExact.contains(lower) { return nil }
        if lower.hasPrefix("zoom") { return nil }
        if name.allSatisfy({ $0.isNumber || $0.isWhitespace }) { return nil }
        if name.contains("@") { return nil }
        return name
    }

    private static func deduped(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(name)
        }
        return out
    }

    private static func role(_ element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute as CFString) ?? "?"
    }

    private static func attribute(_ element: AXUIElement, _ key: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// Returns all windows from the application root element, including those on
    /// other screens, Spaces, or that are minimized. `kAXChildrenAttribute` misses
    /// these; `kAXWindowsAttribute` is the complete list.
    private static func allWindows(_ app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// The focused window — accessible even when on an inactive Space, unlike
    /// `kAXWindowsAttribute` which returns an empty list for windows on other
    /// Spaces. The focused window's full AX subtree (participant tiles, etc.)
    /// remains available regardless of which Space it's on.
    private static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        // kAXFocusedWindowAttribute returns an AXUIElement, but the CFTypeRef could
        // hold something else on a rare AX failure — check the CF type ID rather
        // than force-unwrapping so an unexpected value doesn't crash the poller.
        // `as?` on a CF toll-free-bridged type is flagged as always-succeeding, so
        // compare CFTypeIDs explicitly.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
