import Foundation

/// Canonical notice tokens stored on `Meeting.notice`, plus presentation for the UI.
enum MeetingNotice {
    static let micTranscriptionFailed = "notice:mic_transcription_failed"
    static let callTranscriptionFailed = "notice:call_transcription_failed"
    static let noAudioTranscribed = "notice:no_audio_transcribed"
    static let speakerIdentificationUnavailable = "notice:speaker_identification_unavailable"

    struct Presentation: Equatable {
        let title: String
        let message: String
        let systemImage: String
        /// True when the meeting has no usable transcript at all.
        let isEmptyTranscript: Bool
    }

    /// Notice to show in the UI — hides total-failure copy when a transcript exists.
    static func effectivePresentation(for notice: String?, hasTranscript: Bool) -> Presentation? {
        guard let presentation = presentation(for: notice) else { return nil }
        if hasTranscript && presentation.isEmptyTranscript { return nil }
        return presentation
    }

    /// Collapses notice tokens after processing when live/batch transcript content exists.
    static func finalizedNotice(
        _ notices: [String],
        hasTranscriptContent: Bool
    ) -> String? {
        var filtered = notices
        if hasTranscriptContent {
            if filtered.contains(micTranscriptionFailed), filtered.contains(callTranscriptionFailed) {
                filtered.removeAll {
                    $0 == micTranscriptionFailed || $0 == callTranscriptionFailed
                }
            }
            filtered.removeAll { legacyIndicatesTotalTranscriptionFailure($0) }
            let joined = filtered.isEmpty ? nil : filtered.joined(separator: " ")
            if let joined, presentation(for: joined)?.isEmptyTranscript == true { return nil }
            return joined
        }
        return filtered.isEmpty ? nil : filtered.joined(separator: " ")
    }

    static func presentation(for notice: String?) -> Presentation? {
        guard let notice, !notice.isEmpty else { return nil }
        if notice.contains("audio could not be saved") {
            return Presentation(title: "Incomplete audio recording", message: notice,
                                systemImage: "exclamationmark.triangle", isEmptyTranscript: false)
        }

        let parts = notice.split(separator: " ").map(String.init)
        let micFailed = parts.contains(micTranscriptionFailed)
        let callFailed = parts.contains(callTranscriptionFailed)
        if micFailed || callFailed {
            return transcriptionFailed(mic: micFailed, call: callFailed)
        }

        if parts.count == 1, let single = parts.first {
            switch single {
            case noAudioTranscribed:
                return emptyTranscript
            case speakerIdentificationUnavailable:
                return speakerIdentification
            default:
                break
            }
        }

        return legacyPresentation(for: notice)
    }

    static var emptyTranscript: Presentation {
        Presentation(
            title: "No speech captured",
            message: "Nutola didn't detect any speech in this recording. Resume if the meeting is still live, or write notes manually.",
            systemImage: "waveform.slash",
            isEmptyTranscript: true)
    }

    private static var speakerIdentification: Presentation {
        Presentation(
            title: "Speaker names unavailable",
            message: "The transcript is ready, but Nutola couldn't identify who said what. You can still read and edit the notes.",
            systemImage: "person.2.slash",
            isEmptyTranscript: false)
    }

    private static func transcriptionFailed(mic: Bool, call: Bool) -> Presentation {
        switch (mic, call) {
        case (true, true):
            return Presentation(
                title: "Couldn't transcribe this recording",
                message: "Nutola ran into a problem reading the audio. If the meeting is still going, resume recording to capture the rest.",
                systemImage: "waveform.badge.exclamationmark",
                isEmptyTranscript: true)
        case (true, false):
            return Presentation(
                title: "Your microphone wasn't transcribed",
                message: "Nutola couldn't read your side of the call. The other side may still appear in the transcript.",
                systemImage: "mic.slash",
                isEmptyTranscript: false)
        case (false, true):
            return Presentation(
                title: "Call audio wasn't transcribed",
                message: "Nutola couldn't read the other side of the call. Your microphone may still appear in the transcript.",
                systemImage: "speaker.slash",
                isEmptyTranscript: false)
        case (false, false):
            return Presentation(
                title: "Transcription paused",
                message: "Something went wrong while transcribing this recording.",
                systemImage: "waveform.badge.exclamationmark",
                isEmptyTranscript: false)
        }
    }

    private static func legacyIndicatesTotalTranscriptionFailure(_ notice: String) -> Bool {
        let lower = notice.lowercased()
        let micFailed = lower.contains("mic transcription failed")
        let callFailed = lower.contains("call transcription failed")
        return micFailed && callFailed
    }

    private static func legacyPresentation(for notice: String) -> Presentation {
        let lower = notice.lowercased()
        let micFailed = lower.contains("mic transcription failed")
        let callFailed = lower.contains("call transcription failed")
        if micFailed || callFailed {
            return transcriptionFailed(mic: micFailed, call: callFailed)
        }

        if lower.contains("no audio could be transcribed")
            || lower.contains("nothing to summarize")
            || lower.contains("transcript was empty") {
            return emptyTranscript
        }

        if lower.contains("speaker identification unavailable") {
            return speakerIdentification
        }

        if lower.contains("microphone wasn't recorded") || lower.contains("system audio wasn't recorded") {
            return Presentation(
                title: "Partial recording",
                message: notice,
                systemImage: "waveform.badge.mic",
                isEmptyTranscript: false)
        }

        if lower.contains("avfaudio error") || lower.contains("com.apple.coreaudio") {
            return transcriptionFailed(mic: true, call: true)
        }

        if lower.contains("summary failed") || lower.contains("summary skipped") {
            return Presentation(
                title: "Couldn't generate notes",
                message: notice,
                systemImage: "sparkles",
                isEmptyTranscript: false)
        }

        return Presentation(
            title: "Something went wrong",
            message: notice,
            systemImage: "exclamationmark.circle",
            isEmptyTranscript: false)
    }
}
