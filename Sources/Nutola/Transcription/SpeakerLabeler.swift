import Foundation

enum SpeakerLabeler {
    /// Silence between consecutive words that forces a new segment even for the same speaker.
    private static let maxWordGap: TimeInterval = 1.5

    static func label(
        mic: TranscriptionOutput?,
        system: TranscriptionOutput?,
        systemTurns: [DiarizedTurn]?,
        myName: String,
        namedSpeakers: Bool = false,
        echoEvidence: AcousticEchoEvidence? = nil
    ) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        var segments: [TranscriptSegment] = []
        var speakers: [Speaker] = []

        if let mic {
            let micSegments = mic.segments.map {
                TranscriptSegment(speakerID: "me", start: $0.start, end: $0.end, text: $0.text)
            }
            if !micSegments.isEmpty {
                speakers.append(Speaker(id: "me", name: myName, isMe: true))
            }
            segments.append(contentsOf: micSegments)
        }

        if let system {
            let (systemSegments, systemSpeakers) = labelSystem(
                system, turns: systemTurns, namedSpeakers: namedSpeakers)
            segments.append(contentsOf: systemSegments)
            speakers.append(contentsOf: systemSpeakers)
        }

        // Stable merge: mic segments precede system segments on start-time ties.
        let merged = segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        // On speakers (no headphones) the far end bleeds into the mic and gets
        // transcribed a second time under "me"; drop those echoed duplicates.
        let deduped = dropEchoedMic(merged, evidence: echoEvidence)
        let present = Set(deduped.map(\.speakerID))
        let speakersOut = speakers.filter { present.contains($0.id) }
        let mode = namedSpeakers ? "hybrid/Zoom names"
            : (systemTurns != nil ? "diarized" : "flat")
        NutolaConsoleLog.pipeline(
            "labeled \(deduped.count) segments, \(speakersOut.count) speakers (\(mode)): \(speakersOut.map(\.name).joined(separator: ", "))")
        return (deduped, speakersOut)
    }

    private static func labelSystem(
        _ system: TranscriptionOutput,
        turns: [DiarizedTurn]?,
        namedSpeakers: Bool
    ) -> ([TranscriptSegment], [Speaker]) {
        guard let turns, !turns.isEmpty else {
            let segs = system.segments.map {
                TranscriptSegment(speakerID: "s1", start: $0.start, end: $0.end, text: $0.text)
            }
            return (segs, segs.isEmpty ? [] : [Speaker(id: "s1", name: "Speaker 1")])
        }

        var idForTurnKey: [String: String] = [:]
        var speakers: [Speaker] = []
        var segments: [TranscriptSegment] = []
        var groupWords: [TranscribedWord] = []
        var groupSpeakerID = ""

        func flush() {
            guard let first = groupWords.first, let last = groupWords.last else { return }
            let text = groupWords
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            segments.append(
                TranscriptSegment(speakerID: groupSpeakerID, start: first.start, end: last.end, text: text)
            )
            groupWords.removeAll()
        }

        for word in system.words {
            let key = turns[turnIndex(for: word, in: turns)].speaker
            let speakerID: String
            if let existing = idForTurnKey[key] {
                speakerID = existing
            } else {
                speakerID = "s\(speakers.count + 1)"
                idForTurnKey[key] = speakerID
                let displayName = displayName(for: key, namedSpeakers: namedSpeakers, index: speakers.count + 1)
                speakers.append(Speaker(id: speakerID, name: displayName))
            }
            let gap = groupWords.last.map { word.start - $0.end } ?? 0
            if speakerID != groupSpeakerID || gap > maxWordGap {
                flush()
            }
            groupSpeakerID = speakerID
            groupWords.append(word)
        }
        flush()
        return mergePhantomSpeakers(segments, speakers)
    }

    private static func turnIndex(for word: TranscribedWord, in turns: [DiarizedTurn]) -> Int {
        var bestIndex = 0
        var bestOverlap: TimeInterval = 0
        for (i, turn) in turns.enumerated() {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = i
            }
        }
        if bestOverlap > 0 { return bestIndex }

        let wordMid = (word.start + word.end) / 2
        var nearest = 0
        var bestDistance = TimeInterval.infinity
        for (i, turn) in turns.enumerated() {
            let distance = abs((turn.start + turn.end) / 2 - wordMid)
            if distance < bestDistance {
                bestDistance = distance
                nearest = i
            }
        }
        return nearest
    }

    // MARK: - Cleanup

    private static func displayName(
        for key: String, namedSpeakers: Bool, index: Int
    ) -> String {
        guard namedSpeakers else { return "Speaker \(index)" }
        if key.hasPrefix("S"), key.dropFirst().allSatisfy(\.isNumber) {
            return "Speaker \(key.dropFirst())"
        }
        return key
    }

    /// FluidAudio can fragment one remote voice into several clusters (worst on
    /// uncapped, no-calendar calls). Fold any speaker holding only a sliver of the
    /// total speech into the dominant speaker, so a 1:1 doesn't surface as
    /// "Speaker 1" + "Speaker 2" for the same person.
    private static func mergePhantomSpeakers(
        _ segments: [TranscriptSegment], _ speakers: [Speaker]
    ) -> ([TranscriptSegment], [Speaker]) {
        guard speakers.count > 1 else { return (segments, speakers) }
        var duration: [String: TimeInterval] = [:]
        for s in segments { duration[s.speakerID, default: 0] += max(0, s.end - s.start) }
        let total = duration.values.reduce(0, +)
        guard total > 0, let dominant = duration.max(by: { $0.value < $1.value })?.key else {
            return (segments, speakers)
        }
        // A real speaker holds more than a few seconds AND a non-trivial share.
        let phantoms = Set(speakers.map(\.id).filter { id in
            id != dominant
                && duration[id, default: 0] < 4
                && duration[id, default: 0] / total < 0.10
        })
        guard !phantoms.isEmpty else { return (segments, speakers) }
        let remapped = segments.map { seg in
            phantoms.contains(seg.speakerID)
                ? TranscriptSegment(speakerID: dominant, start: seg.start, end: seg.end, text: seg.text)
                : seg
        }
        let present = Set(remapped.map(\.speakerID))
        return (remapped, speakers.filter { present.contains($0.id) })
    }

    /// Requires corroboration from BOTH the remote transcript and acoustic
    /// cross-channel correlation before removing an apparent microphone echo.
    /// When audio evidence is unavailable, retain the existing conservative
    /// text-only behavior for backwards compatibility.
    private static func dropEchoedMic(
        _ segments: [TranscriptSegment], evidence: AcousticEchoEvidence?
    ) -> [TranscriptSegment] {
        let others = segments.filter { $0.speakerID != "me" }
        guard !others.isEmpty else { return segments }
        return segments.filter { seg in
            guard seg.speakerID == "me" else { return true }
            let tokens = TranscriptText.wordTokens(seg.text)
            guard tokens.count >= 2 else { return true }
            let nearby = others.filter { overlaps(seg, $0, tolerance: 0.75) }
            guard !nearby.isEmpty else { return true }

            let transcriptMatch: Bool
            if tokens.count <= 3 {
                transcriptMatch = nearby.contains { remote in
                    TranscriptText.wordTokens(remote.text) == tokens
                }
            } else {
                let joined = nearby.sorted { $0.start < $1.start }
                    .map(\.text).joined(separator: " ")
                transcriptMatch = nearby.contains {
                    TranscriptText.covers(seg.text, by: $0.text, atLeast: 0.6)
                } || TranscriptText.covers(seg.text, by: joined, atLeast: 0.6)
            }
            guard transcriptMatch else { return true }

            if let evidence {
                // Audio-level support is necessary; if absent or ambiguous,
                // leave the utterance intact rather than losing real speech.
                return !evidence.stronglyMatches(start: seg.start, end: seg.end)
            }
            // Preserve existing behavior for prior recordings without audio
            // comparison, except additionally discard exact 2-3-word echoes.
            return false
        }
    }

    private static func overlaps(
        _ a: TranscriptSegment, _ b: TranscriptSegment, tolerance: TimeInterval
    ) -> Bool {
        a.start - tolerance < b.end && b.start - tolerance < a.end
    }
}
