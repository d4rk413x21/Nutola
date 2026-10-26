import Foundation
import Testing
@testable import Nutola

struct TranscriptFormatterTests {
    let speakers = [
        Speaker(id: "me", name: "Me", isMe: true),
        Speaker(id: "s1", name: "Alice"),
        Speaker(id: "s2", name: "Bob"),
    ]

    let segments = [
        TranscriptSegment(speakerID: "me", start: 0, end: 5, text: "Hello world"),
        TranscriptSegment(speakerID: "s1", start: 5, end: 10, text: "Hi there"),
        TranscriptSegment(speakerID: "s2", start: 10, end: 15, text: "Good to see you"),
    ]

    // MARK: - SRT

    @Test func testSRTFormat() {
        let srt = TranscriptFormatter.srt(segments, speakers: speakers)

        // Sequential indices for each segment.
        #expect(srt.contains("1\n"))
        #expect(srt.contains("2\n"))
        #expect(srt.contains("3\n"))

        // Comma-separated SRT timestamps.
        #expect(srt.contains("00:00:00,000 --> 00:00:05,000"))
        #expect(srt.contains("00:00:05,000 --> 00:00:10,000"))
        #expect(srt.contains("00:00:10,000 --> 00:00:15,000"))

        // Speaker name prefix on cue lines.
        #expect(srt.contains("Me: Hello world"))
        #expect(srt.contains("Alice: Hi there"))
        #expect(srt.contains("Bob: Good to see you"))

        // Entries are blank-line separated (three entries → two double-newlines).
        #expect(srt.components(separatedBy: "\n\n").count == 3)
    }

    @Test func testSRTEmpty() {
        #expect(TranscriptFormatter.srt([], speakers: speakers) == "")
    }

    @Test func testSRTUnknownSpeakerFallsBackToID() {
        let seg = [TranscriptSegment(speakerID: "ghost", start: 0, end: 1, text: "Boo")]
        let srt = TranscriptFormatter.srt(seg, speakers: speakers)
        #expect(srt.contains("ghost: Boo"))
    }

    // MARK: - VTT

    @Test func testVTTFormat() {
        let vtt = TranscriptFormatter.vtt(segments, speakers: speakers)

        // Header.
        #expect(vtt.hasPrefix("WEBVTT\n\n"))

        // Dot-separated VTT timestamps.
        #expect(vtt.contains("00:00:00.000 --> 00:00:05.000"))
        #expect(vtt.contains("00:00:05.000 --> 00:00:10.000"))
        #expect(vtt.contains("00:00:10.000 --> 00:00:15.000"))

        // WebVTT speaker tags; no sequential indices.
        #expect(vtt.contains("<v Me> Hello world"))
        #expect(vtt.contains("<v Alice> Hi there"))
        #expect(vtt.contains("<v Bob> Good to see you"))
        #expect(!(vtt.contains("\n1\n")))
        #expect(!(vtt.contains("\n2\n")))

        // Three cues separated by blank lines (after the header).
        let body = vtt.dropFirst("WEBVTT\n\n".count)
        #expect(body.components(separatedBy: "\n\n").count == 3)
    }

    @Test func testVTTEmpty() {
        // No segments → just the header.
        #expect(TranscriptFormatter.vtt([], speakers: speakers) == "WEBVTT\n\n")
    }

    @Test func testVTTUnknownSpeakerFallsBackToID() {
        let seg = [TranscriptSegment(speakerID: "ghost", start: 0, end: 1, text: "Boo")]
        let vtt = TranscriptFormatter.vtt(seg, speakers: speakers)
        #expect(vtt.contains("<v ghost> Boo"))
    }

    // MARK: - subtitleTimestamp (via srt/vtt output)

    @Test func testSubtitleTimestampAtZero() {
        let seg = [TranscriptSegment(speakerID: "me", start: 0, end: 0, text: "Go")]
        let srt = TranscriptFormatter.srt(seg, speakers: speakers)
        #expect(srt.contains("00:00:00,000 --> 00:00:00,000"))
    }

    @Test func testSubtitleTimestampAt65Seconds() {
        // 65s → 00:01:05
        let seg = [TranscriptSegment(speakerID: "me", start: 65, end: 66, text: "Go")]
        let srt = TranscriptFormatter.srt(seg, speakers: speakers)
        #expect(srt.contains("00:01:05,000 --> 00:01:06,000"))
    }

    @Test func testSubtitleTimestampAt3661Seconds() {
        // 3661s = 1h 1m 1s → 01:01:01
        let seg = [TranscriptSegment(speakerID: "me", start: 3661, end: 3662, text: "Go")]
        let vtt = TranscriptFormatter.vtt(seg, speakers: speakers)
        #expect(vtt.contains("01:01:01.000 --> 01:01:02.000"))
    }

    @Test func testSubtitleTimestampMilliseconds() {
        // Fractional seconds round to the nearest millisecond.
        let seg = [TranscriptSegment(speakerID: "me", start: 1.234, end: 2.567, text: "Go")]
        let srt = TranscriptFormatter.srt(seg, speakers: speakers)
        #expect(srt.contains("00:00:01,234 --> 00:00:02,567"))
    }
}
