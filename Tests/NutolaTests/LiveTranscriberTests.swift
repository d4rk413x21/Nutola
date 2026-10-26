import AVFoundation
import Foundation
import Testing
@testable import Nutola

struct LiveTranscriberTests {
    @Test func testAudioCopyOwnsItsSamplesBeforeTransfer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        source.frameLength = 2
        let samples = try #require(source.floatChannelData)
        samples[0][0] = 0.25
        samples[0][1] = 0.5
        samples[1][0] = -0.25
        samples[1][1] = -0.5

        let copy = try #require(LiveTranscriber.copy(source))
        samples[0][0] = 1
        samples[1][1] = 1
        let copied = try #require(copy.floatChannelData)
        #expect(copy.frameLength == 2)
        #expect(copy.format == source.format)
        #expect(copied[0][0] == 0.25)
        #expect(copied[0][1] == 0.5)
        #expect(copied[1][0] == -0.25)
        #expect(copied[1][1] == -0.5)
    }

    @Test func testTurnsGroupConsecutiveSameSpeaker() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 0, text: "Hi"),
            TranscriptSegment(speakerID: "me", start: 1, end: 1, text: "there"),
            TranscriptSegment(speakerID: "them", start: 2, end: 2, text: "Hello"),
            TranscriptSegment(speakerID: "me", start: 3, end: 3, text: "again"),
        ]
        let turns = LiveTranscriber.turns(from: segments)
        #expect(turns.count == 3)
        #expect(turns[0].speakerID == "me")
        #expect(turns[0].text == "Hi there")
        #expect(turns[1].speakerID == "them")
        #expect(turns[1].text == "Hello")
        #expect(turns[2].text == "again")
        // Ids are the running index, so ForEach stays stable as segments append.
        #expect(turns.map(\.id) == [0, 1, 2])
    }

    @Test func testTurnsEmpty() {
        #expect(LiveTranscriber.turns(from: []).isEmpty)
    }

    @Test func testNameMapsSyntheticSpeakers() {
        #expect(LiveTranscriber.name(for: LiveTranscriber.youSpeakerID) == "You")
        #expect(LiveTranscriber.name(for: LiveTranscriber.othersSpeakerID) == "Others")
        #expect(LiveTranscriber.name(for: "unmapped") == "unmapped")
    }

    // MARK: - Live echo dedup

    private func seg(_ speakerID: String, _ t: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerID: speakerID, start: t, end: t, text: text)
    }

    private func dedup(_ segments: inout [TranscriptSegment], around anchor: TimeInterval) {
        LiveTranscriber.removeEchoedMicSegments(
            around: anchor, in: &segments, window: LiveTranscriber.liveEchoWindow)
    }

    @Test func testDropsLiveMicEchoWhenSystemArrivesFirst() {
        // The far end's clean copy finalized first; the mic echo lands right after.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 5.2, "let's lock the launch date"),
        ]
        dedup(&segments, around: 5.2)
        #expect(segments.map(\.speakerID) == ["them"])
    }

    @Test func testDropsLiveMicEchoRetroactivelyWhenSystemArrivesLast() {
        // The mic echo finalized first; the clean system copy lands a beat later and
        // should still remove it. The pass is bidirectional.
        var segments = [
            seg("me", 5.0, "let's lock the launch date"),
            seg("them", 5.3, "let's lock the launch date"),
        ]
        dedup(&segments, around: 5.3)
        #expect(segments.map(\.speakerID) == ["them"])
    }

    @Test func testKeepsShortLiveMicBackchannel() {
        // A brief affirmation that happens to echo shouldn't be nuked.
        var segments = [seg("them", 3.0, "yeah"), seg("me", 3.2, "yeah")]
        dedup(&segments, around: 3.2)
        #expect(segments.map(\.speakerID) == ["them", "me"])
    }

    @Test func testKeepsGenuineLiveMicSpeech() {
        var segments = [
            seg("them", 5.0, "how is the roadmap looking"),
            seg("me", 6.0, "sounds good to me here"),
        ]
        dedup(&segments, around: 6.0)
        #expect(segments.count == 2)
        #expect(segments.contains { $0.speakerID == "me" })
    }

    @Test func testEchoDedupIgnoresSegmentsOutsideWindow() {
        // A matching system line 15s earlier is a different utterance, not an echo.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 20.0, "let's lock the launch date"),
        ]
        dedup(&segments, around: 20.0)
        #expect(segments.count == 2, "the old system line is out of window, so no echo match")
    }

    @Test func testKeepsGenuineMicLineThatMerelySharesVocabulary() {
        // A genuine local line that reuses a few of the far end's words (0.6 coverage)
        // must NOT be dropped — only near-verbatim echoes (>=0.75) are.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 8.5, "lock in the date then"),   // 3/5 words overlap = 0.6
        ]
        dedup(&segments, around: 8.5)
        #expect(segments.contains { $0.speakerID == "me" }, "coincidental vocabulary overlap kept")
    }

    @Test func testEchoDedupKeepsGenuineMicLineWithinWindowOfEcho() {
        // Within one window: an echo plus a genuine local line. Only the echo drops.
        var segments = [
            seg("them", 5.0, "let's lock the launch date"),
            seg("me", 5.2, "let's lock the launch date"),        // echo of the far end
            seg("me", 6.5, "works for everyone on our side"),    // genuine local line
        ]
        dedup(&segments, around: 5.2)
        let meTexts = segments.filter { $0.speakerID == "me" }.map(\.text)
        #expect(meTexts == ["works for everyone on our side"])
    }

    @Test func testHeadphoneBleedRemovesMicNearOthersWithSharedVocabulary() {
        var segments = [
            seg("me", 80.0, "and then repeat Jesus and more words here"),
            seg("them", 80.5, "you speak and then repeat Jesus and then English"),
        ]
        LiveTranscriber.removeHeadphoneBleedMic(
            around: 80.5, othersText: segments[1].text, in: &segments, window: 3.0)
        #expect(segments.map(\.speakerID) == ["them"])
    }

    @Test func testSpeakerphoneEchoMatchesRemoteTextWithoutHeadphones() {
        let local = seg("me", 100.4, "dobbiamo aggiornare i dati delle statistiche")
        let remote = seg("them", 100.0, "Dobbiamo aggiornare i dati delle statistiche")
        #expect(LiveTranscriber.isPlaybackEcho(local, among: [remote]))
    }

    @Test func testSpeakerphoneEchoMatchesNamedRemoteSpeaker() {
        let local = seg("me", 120.2, "bisogna aggiornare la procedura al più presto")
        let remote = seg("Giulia", 121.3, "bisogna aggiornare la procedura al più presto")
        #expect(LiveTranscriber.isPlaybackEcho(local, among: [remote]))
    }

    @Test func testSpeakerphoneEchoMatchesSplitRemoteSentences() {
        let local = seg("me", 155, "dobbiamo completare la migrazione dello storage")
        let remote = [
            seg("them", 154, "dobbiamo completare la migrazione"),
            seg("them", 156, "dello storage")
        ]
        #expect(LiveTranscriber.isPlaybackEcho(local, among: remote))
    }

    @Test func testSpeakerphoneEchoPreservesRealLocalInterruption() {
        let local = seg("me", 50.2, "no la modifica va fatta dopo il rilascio")
        let remote = seg("them", 50, "la migrazione dello storage è pronta")
        #expect(!(LiveTranscriber.isPlaybackEcho(local, among: [remote])))
    }

    @Test func testSpeakerphoneEchoDoesNotDeleteDifferentConversation() {
        let local = seg("me", 90, "dobbiamo completare la migrazione dello storage")
        let remote = seg("them", 80, "dobbiamo completare la migrazione dello storage")
        #expect(!(LiveTranscriber.isPlaybackEcho(local, among: [remote])))
    }

    @Test func testUnverifiedMicrophoneVolatileHiddenOnlyDuringPlayback() {
        let texts = ["me": "parlo io", "them": "parlano gli altri"]
        let masked = LiveTranscriber.formattedVolatile(texts, suppressUnverifiedMic: true)
        #expect(!(masked.contains("parlo io")))
        #expect(masked.contains("parlano gli altri"))
        #expect(LiveTranscriber.formattedVolatile(texts).contains("parlo io"))
    }

    @Test func testFormattedVolatileLabelsChannels() {
        let text = LiveTranscriber.formattedVolatile([
            LiveTranscriber.youSpeakerID: "hello",
            LiveTranscriber.othersSpeakerID: "hi there",
        ])
        #expect(text.contains("You: hello"))
        #expect(text.contains("Others: hi there"))
    }

    @Test func testRemoteSpeechPeakThreshold() {
        #expect(LiveTranscriber.remoteSpeechPeakThreshold > 0.01)
    }
}
