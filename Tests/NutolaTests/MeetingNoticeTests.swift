import Foundation
import Testing
@testable import Nutola

struct MeetingNoticeTests {
    @Test func testCanonicalTranscriptionFailuresCombine() {
        let notice = "\(MeetingNotice.micTranscriptionFailed) \(MeetingNotice.callTranscriptionFailed)"
        let presentation = MeetingNotice.presentation(for: notice)
        #expect(presentation?.title == "Couldn't transcribe this recording")
        #expect(presentation?.isEmptyTranscript == true)
    }

    @Test func testLegacyAvfaudioErrorsBecomeFriendlyCopy() {
        let notice = """
        Mic transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.) \
        Call transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.)
        """
        let presentation = MeetingNotice.presentation(for: notice)
        #expect(presentation?.title == "Couldn't transcribe this recording")
        #expect(!(presentation?.message.contains("avfaudio") == true))
    }

    @Test func testNoAudioTokenMapsToEmptyTranscript() {
        let presentation = MeetingNotice.presentation(for: MeetingNotice.noAudioTranscribed)
        #expect(presentation?.title == "No speech captured")
        #expect(presentation?.isEmptyTranscript == true)
    }

    @Test func testEffectivePresentationHidesTotalFailureWhenTranscriptExists() {
        let notice = "\(MeetingNotice.micTranscriptionFailed) \(MeetingNotice.callTranscriptionFailed)"
        #expect(MeetingNotice.effectivePresentation(for: notice, hasTranscript: true) == nil)
        #expect(MeetingNotice.effectivePresentation(for: notice, hasTranscript: false) != nil)
    }

    @Test func testEffectivePresentationKeepsPartialFailureWhenTranscriptExists() {
        let notice = MeetingNotice.micTranscriptionFailed
        let presentation = MeetingNotice.effectivePresentation(for: notice, hasTranscript: true)
        #expect(presentation?.title == "Your microphone wasn't transcribed")
        #expect(!(presentation?.isEmptyTranscript == true))
    }

    @Test func testFinalizedNoticeClearsBothFailuresWhenTranscriptExists() {
        let notices = [MeetingNotice.micTranscriptionFailed, MeetingNotice.callTranscriptionFailed]
        #expect(MeetingNotice.finalizedNotice(notices, hasTranscriptContent: true) == nil)
        #expect(MeetingNotice.finalizedNotice(notices, hasTranscriptContent: false) == "\(MeetingNotice.micTranscriptionFailed) \(MeetingNotice.callTranscriptionFailed)")
    }

    @Test func testFinalizedNoticeClearsLegacyBothFailuresWhenTranscriptExists() {
        let legacy = """
        Mic transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.) \
        Call transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.)
        """
        #expect(MeetingNotice.finalizedNotice([legacy], hasTranscriptContent: true) == nil)
    }
}
