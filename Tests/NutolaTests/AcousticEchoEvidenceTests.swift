import AVFoundation
import Foundation
import Testing
@testable import Nutola

struct AcousticEchoEvidenceTests {
    @Test func testMatchedDelayedPlaybackHasHighCorrelation() {
        let system: [Float] = (0..<220).map { i in
            { let x = Double(i); let a = abs(sin(x * 0.31)); let b = abs(cos(x * 0.13)); return Float(0.02 + 0.025 * a + 0.01 * b) }()
        }
        let mic: [Float] = (0..<220).map { i in
            i >= 8 ? system[i - 8] * 0.6 : 0.005
        }
        let evidence = AcousticEchoEvidence(microphone: mic, system: system)
        #expect(evidence.stronglyMatches(start: 1.0, end: 2.8))
    }

    @Test func testDifferentSpeechEnvelopeDoesNotMatch() {
        let system: [Float] = (0..<220).map { i in
            (i % 37 < 7) ? 0.1 : 0.006
        }
        let mic: [Float] = (0..<220).map { i in
            (i % 23 < 3) ? 0.09 : 0.004
        }
        let evidence = AcousticEchoEvidence(microphone: mic, system: system)
        #expect(!(evidence.stronglyMatches(start: 1.0, end: 3.0)))
    }

    @Test func testSilenceIsNotEchoEvidence() {
        let evidence = AcousticEchoEvidence(
            microphone: Array(repeating: 0, count: 150),
            system: Array(repeating: 0, count: 150))
        #expect(evidence.bestCorrelation(start: 0, end: 2) == nil)
        #expect(!(evidence.stronglyMatches(start: 0, end: 2)))
    }

    @Test func testEnvelopeDecoderReadsRecordedPCMAndBoundsToAvailableAudio() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-echo-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frameCount = 96_000
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let channel = buffer.floatChannelData![0]
            for index in 0..<frameCount {
                let bin = index / 960
                let amplitude = Float(0.01 + 0.08 * abs(sin(Double(bin) * 0.38)))
                channel[index] = amplitude * Float(sin(Double(index) * 0.07))
            }
            try file.write(from: buffer)
        }
        // Drop the writer before reopening the same WAV as a reader.
        let evidence = try AcousticEchoEvidence.load(microphoneURL: url, systemURL: url)
        #expect(evidence.microphone.count > 90)
        #expect(evidence.stronglyMatches(start: 0.3, end: 1.7))
        #expect(evidence.bestCorrelation(start: 10, end: 12) == nil)
    }

    @Test func testTooShortIntervalIsNotEvidence() {
        let evidence = AcousticEchoEvidence(
            microphone: Array(repeating: 0.2, count: 100),
            system: Array(repeating: 0.2, count: 100))
        #expect(evidence.bestCorrelation(start: 0, end: 0.2) == nil)
    }
}
