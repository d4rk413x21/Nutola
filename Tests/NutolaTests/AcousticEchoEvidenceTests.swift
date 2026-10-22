import XCTest
@testable import Nutola

final class AcousticEchoEvidenceTests: XCTestCase {
    func testMatchedDelayedPlaybackHasHighCorrelation() {
        let system: [Float] = (0..<220).map { i in
            { let x = Double(i); let a = abs(sin(x * 0.31)); let b = abs(cos(x * 0.13)); return Float(0.02 + 0.025 * a + 0.01 * b) }()
        }
        let mic: [Float] = (0..<220).map { i in
            i >= 8 ? system[i - 8] * 0.6 : 0.005
        }
        let evidence = AcousticEchoEvidence(microphone: mic, system: system)
        XCTAssertTrue(evidence.stronglyMatches(start: 1.0, end: 2.8))
    }

    func testDifferentSpeechEnvelopeDoesNotMatch() {
        let system: [Float] = (0..<220).map { i in
            (i % 37 < 7) ? 0.1 : 0.006
        }
        let mic: [Float] = (0..<220).map { i in
            (i % 23 < 3) ? 0.09 : 0.004
        }
        let evidence = AcousticEchoEvidence(microphone: mic, system: system)
        XCTAssertFalse(evidence.stronglyMatches(start: 1.0, end: 3.0))
    }

    func testSilenceIsNotEchoEvidence() {
        let evidence = AcousticEchoEvidence(
            microphone: Array(repeating: 0, count: 150),
            system: Array(repeating: 0, count: 150))
        XCTAssertNil(evidence.bestCorrelation(start: 0, end: 2))
        XCTAssertFalse(evidence.stronglyMatches(start: 0, end: 2))
    }

    func testTooShortIntervalIsNotEvidence() {
        let evidence = AcousticEchoEvidence(
            microphone: Array(repeating: 0.2, count: 100),
            system: Array(repeating: 0.2, count: 100))
        XCTAssertNil(evidence.bestCorrelation(start: 0, end: 0.2))
    }
}
