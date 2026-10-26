import Foundation

/// Renders transcripts as text for prompts, export, editing, and MCP responses.
enum TranscriptFormatter {
    static func clipboardText(meeting: Meeting, saved: [TranscriptSegment], liveMeetingID: UUID?,
                              live: [TranscriptSegment], localName: String, remoteName: String) -> String {
        let includeLive = liveMeetingID == meeting.id
        var speakers = meeting.speakers
        if includeLive {
            for speaker in [Speaker(id: LiveTranscriber.youSpeakerID, name: localName, isMe: true),
                            Speaker(id: LiveTranscriber.othersSpeakerID, name: remoteName)]
            where !speakers.contains(where: { $0.id == speaker.id }) {
                speakers.append(speaker)
            }
        }
        return plainText(saved + (includeLive ? live : []), speakers: speakers)
    }

    /// "Alice @ 12:04: We should ship on Friday."
    static func plainText(_ segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        return segments.map { seg in
            let who = names[seg.speakerID] ?? seg.speakerID
            return "\(who) @ \(MeetingArchive.timestamp(seg.start)): \(seg.text)"
        }
        .joined(separator: "\n")
    }

    /// Markdown with bolded speaker turns; consecutive segments by the same speaker merge
    /// into one paragraph for readability.
    static func markdown(_ segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var out: [String] = []
        var currentSpeaker: String?
        var currentTexts: [String] = []
        var currentStart: TimeInterval = 0

        func flush() {
            guard let s = currentSpeaker, !currentTexts.isEmpty else { return }
            let who = names[s] ?? s
            out.append("**\(who)** · \(MeetingArchive.timestamp(currentStart))\n\(currentTexts.joined(separator: " "))")
        }

        for seg in segments {
            if seg.speakerID != currentSpeaker {
                flush()
                currentSpeaker = seg.speakerID
                currentTexts = []
                currentStart = seg.start
            }
            currentTexts.append(seg.text)
        }
        flush()
        return out.joined(separator: "\n\n")
    }

    /// Parse the editable plain-text form back into segments. Lines that match
    /// "Name @ m:ss: text" update speaker/text; unmatched lines append to the previous
    /// segment. Unknown speaker names create new speakers. Returns updated segments+speakers.
    static func parseEdited(
        _ text: String,
        originalSegments: [TranscriptSegment],
        speakers: [Speaker]
    ) -> ([TranscriptSegment], [Speaker]) {
        var speakers = speakers
        var idsByName = Dictionary(speakers.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        let namesByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var segments: [TranscriptSegment] = []
        var nextSpeakerNum = speakers.filter { !$0.isMe }.count + 1

        let pattern = #/^(.+?) @ (\d+):(\d{2}): ?(.*)$/#
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let m = try? pattern.wholeMatch(in: line) {
                let name = String(m.1).trimmingCharacters(in: .whitespaces)
                let minutes: Int = Int(m.2) ?? 0
                let seconds: Int = Int(m.3) ?? 0
                let start = TimeInterval(minutes * 60 + seconds)
                let body = String(m.4)
                let original = originalSegments.first { abs($0.start - start) < 0.5 }

                // Display names aren't unique (two Alexes), so identity resolves
                // by timestamp first: an unchanged name on a line keeps that
                // line's original speaker id. Name lookup is only for lines the
                // user deliberately reassigned.
                let speakerID: String
                if let original, namesByID[original.speakerID] == name {
                    speakerID = original.speakerID
                } else if let existing = idsByName[name] {
                    speakerID = existing
                } else {
                    speakerID = "s\(nextSpeakerNum)"
                    nextSpeakerNum += 1
                    speakers.append(Speaker(id: speakerID, name: name))
                    idsByName[name] = speakerID
                }
                segments.append(TranscriptSegment(
                    speakerID: speakerID,
                    start: start,
                    end: original?.end ?? start,
                    text: body
                ))
            } else if !segments.isEmpty {
                segments[segments.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return (segments, speakers)
    }

    /// SubRip (SRT) subtitles: sequential indices, `HH:MM:SS,mmm --> HH:MM:SS,mmm`
    /// timestamps, `SpeakerName: text` lines, blank-line-separated entries.
    static func srt(_ segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        guard !segments.isEmpty else { return "" }
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var entries: [String] = []
        for (i, seg) in segments.enumerated() {
            let who = names[seg.speakerID] ?? seg.speakerID
            entries.append("""
                \(i + 1)
                \(subtitleTimestamp(seg.start, separator: ",")) --> \(subtitleTimestamp(seg.end, separator: ","))
                \(who): \(seg.text)
                """)
        }
        return entries.joined(separator: "\n\n")
    }

    /// WebVTT subtitles: `WEBVTT` header, `HH:MM:SS.mmm --> HH:MM:SS.mmm`
    /// timestamps, `<v SpeakerName> text` cue lines, blank-line-separated cues.
    static func vtt(_ segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var cues: [String] = []
        for seg in segments {
            let who = names[seg.speakerID] ?? seg.speakerID
            cues.append("""
                \(subtitleTimestamp(seg.start, separator: ".")) --> \(subtitleTimestamp(seg.end, separator: "."))
                <v \(who)> \(seg.text)
                """)
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n\n")
    }

    /// Formats `seconds` as `HH:MM:SS{separator}mmm` for subtitle timestamps.
    private static func subtitleTimestamp(_ seconds: TimeInterval, separator: Character) -> String {
        // Floor the integer part and derive milliseconds from the true remainder
        // so the two never double-count a rounding carry (e.g. 2.567 → 00:00:02,567,
        // not 00:00:03,567). When the remainder rounds up to a full second
        // (e.g. 1.9999 → 00:00:02,000) carry it into the integer part.
        // Negative times clamp to zero.
        var floored = max(0, Int(seconds.rounded(.down)))
        var remainder = max(0, seconds - TimeInterval(floored))
        var millis = Int((remainder * 1000).rounded())
        if millis >= 1000 {
            floored += 1
            remainder = 0
            millis = 0
        }
        let hours = floored / 3600
        let minutes = (floored % 3600) / 60
        let secs = floored % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, String(separator), millis)
    }
}
