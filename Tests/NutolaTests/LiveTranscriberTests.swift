import XCTest
@testable import Nutola

final class LiveTranscriberTests: XCTestCase {
    func testTurnsGroupConsecutiveSameSpeaker() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 0, text: "Hi"),
            TranscriptSegment(speakerID: "me", start: 1, end: 1, text: "there"),
            TranscriptSegment(speakerID: "them", start: 2, end: 2, text: "Hello"),
            TranscriptSegment(speakerID: "me", start: 3, end: 3, text: "again"),
        ]
        let turns = LiveTranscriber.turns(from: segments)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].speakerID, "me")
        XCTAssertEqual(turns[0].text, "Hi there")
        XCTAssertEqual(turns[1].speakerID, "them")
        XCTAssertEqual(turns[1].text, "Hello")
        XCTAssertEqual(turns[2].text, "again")
        // Ids are the running index, so ForEach stays stable as segments append.
        XCTAssertEqual(turns.map(\.id), [0, 1, 2])
    }

    func testTurnsEmpty() {
        XCTAssertTrue(LiveTranscriber.turns(from: []).isEmpty)
    }

    func testNameMapsSyntheticSpeakers() {
        XCTAssertEqual(LiveTranscriber.name(for: LiveTranscriber.youSpeakerID), "You")
        XCTAssertEqual(LiveTranscriber.name(for: LiveTranscriber.othersSpeakerID), "Others")
        XCTAssertEqual(LiveTranscriber.name(for: "unmapped"), "unmapped")
    }

    // MARK: - Live echo dedup

    private func seg(_ speakerID: String, _ t: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerID: speakerID, start: t, end: t, text: text)
    }

    private func dedup(_ segments: inout [TranscriptSegment], around anchor: TimeInterval) {
        LiveTranscriber.removeEchoedMicSegments(
            around: anchor, in: &segments, window: LiveTranscriber.liveEchoWindow)
    }

    func testDropsLiveMicEchoWhenSystemArrivesFirst() {
        // The far end's clean copy finalized first; the mic echo lands right after.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 5.2, "let's lock the launch date"),
        ]
        dedup(&segments, around: 5.2)
        XCTAssertEqual(segments.map(\.speakerID), ["them"])
    }

    func testDropsLiveMicEchoRetroactivelyWhenSystemArrivesLast() {
        // The mic echo finalized first; the clean system copy lands a beat later and
        // should still remove it. The pass is bidirectional.
        var segments = [
            seg("me", 5.0, "let's lock the launch date"),
            seg("them", 5.3, "let's lock the launch date"),
        ]
        dedup(&segments, around: 5.3)
        XCTAssertEqual(segments.map(\.speakerID), ["them"])
    }

    func testKeepsShortLiveMicBackchannel() {
        // A brief affirmation that happens to echo shouldn't be nuked.
        var segments = [seg("them", 3.0, "yeah"), seg("me", 3.2, "yeah")]
        dedup(&segments, around: 3.2)
        XCTAssertEqual(segments.map(\.speakerID), ["them", "me"])
    }

    func testKeepsGenuineLiveMicSpeech() {
        var segments = [
            seg("them", 5.0, "how is the roadmap looking"),
            seg("me", 6.0, "sounds good to me here"),
        ]
        dedup(&segments, around: 6.0)
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.contains { $0.speakerID == "me" })
    }

    func testEchoDedupIgnoresSegmentsOutsideWindow() {
        // A matching system line 15s earlier is a different utterance, not an echo.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 20.0, "let's lock the launch date"),
        ]
        dedup(&segments, around: 20.0)
        XCTAssertEqual(segments.count, 2, "the old system line is out of window, so no echo match")
    }

    func testKeepsGenuineMicLineThatMerelySharesVocabulary() {
        // A genuine local line that reuses a few of the far end's words (0.6 coverage)
        // must NOT be dropped — only near-verbatim echoes (>=0.75) are.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 8.5, "lock in the date then"),   // 3/5 words overlap = 0.6
        ]
        dedup(&segments, around: 8.5)
        XCTAssertTrue(segments.contains { $0.speakerID == "me" }, "coincidental vocabulary overlap kept")
    }

    func testEchoDedupKeepsGenuineMicLineWithinWindowOfEcho() {
        // Within one window: an echo plus a genuine local line. Only the echo drops.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 5.2, "let's lock the launch date"),        // echo of the far end
            seg("me", 6.5, "works for everyone on our side"),    // genuine local line
        ]
        dedup(&segments, around: 5.2)
        let meTexts = segments.filter { $0.speakerID == "me" }.map(\.text)
        XCTAssertEqual(meTexts, ["works for everyone on our side"])
    }

    func testHeadphoneBleedRemovesMicNearOthersWithSharedVocabulary() {
        var segments = [
            seg("me", 80.0, "and then repeat Jesus and more words here"),
            seg("them", 80.5, "you speak and then repeat Jesus and then English"),
        ]
        LiveTranscriber.removeHeadphoneBleedMic(
            around: 80.5, othersText: segments[1].text, in: &segments, window: 3.0)
        XCTAssertEqual(segments.map(\.speakerID), ["them"])
    }

    func testSpeakerphoneEchoMatchesRemoteTextWithoutHeadphones() {
        let local = seg("me", 100.4, "dobbiamo aggiornare i dati delle statistiche")
        let remote = seg("them", 100.0, "Dobbiamo aggiornare i dati delle statistiche")
        XCTAssertTrue(LiveTranscriber.isPlaybackEcho(local, among: [remote]))
    }

    func testSpeakerphoneEchoMatchesNamedRemoteSpeaker() {
        let local = seg("me", 120.2, "bisogna aggiornare la procedura al più presto")
        let remote = seg("Giulia", 121.3, "bisogna aggiornare la procedura al più presto")
        XCTAssertTrue(LiveTranscriber.isPlaybackEcho(local, among: [remote]))
    }

    func testSpeakerphoneEchoMatchesSplitRemoteSentences() {
        let local = seg("me", 155, "dobbiamo completare la migrazione dello storage")
        let remote = [
            seg("them", 154, "dobbiamo completare la migrazione"),
            seg("them", 156, "dello storage")
        ]
        XCTAssertTrue(LiveTranscriber.isPlaybackEcho(local, among: remote))
    }

    func testSpeakerphoneEchoPreservesRealLocalInterruption() {
        let local = seg("me", 50.2, "no la modifica va fatta dopo il rilascio")
        let remote = seg("them", 50, "la migrazione dello storage è pronta")
        XCTAssertFalse(LiveTranscriber.isPlaybackEcho(local, among: [remote]))
    }

    func testSpeakerphoneEchoDoesNotDeleteDifferentConversation() {
        let local = seg("me", 90, "dobbiamo completare la migrazione dello storage")
        let remote = seg("them", 80, "dobbiamo completare la migrazione dello storage")
        XCTAssertFalse(LiveTranscriber.isPlaybackEcho(local, among: [remote]))
    }

    func testUnverifiedMicrophoneVolatileHiddenOnlyDuringPlayback() {
        let texts = ["me": "parlo io", "them": "parlano gli altri"]
        let masked = LiveTranscriber.formattedVolatile(texts, suppressUnverifiedMic: true)
        XCTAssertFalse(masked.contains("parlo io"))
        XCTAssertTrue(masked.contains("parlano gli altri"))
        XCTAssertTrue(LiveTranscriber.formattedVolatile(texts).contains("parlo io"))
    }

    func testFormattedVolatileLabelsChannels() {
        let text = LiveTranscriber.formattedVolatile([
            LiveTranscriber.youSpeakerID: "hello",
            LiveTranscriber.othersSpeakerID: "hi there",
        ])
        XCTAssertTrue(text.contains("You: hello"))
        XCTAssertTrue(text.contains("Others: hi there"))
    }

    func testRemoteSpeechPeakThreshold() {
        XCTAssertGreaterThan(LiveTranscriber.remoteSpeechPeakThreshold, 0.01)
    }
}
