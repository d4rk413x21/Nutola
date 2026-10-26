import Foundation
import Testing
import AVFoundation
import ExceptionCatch

struct ExceptionCatchProbeTests {
    /// Reproduces the exact crash path from 2026-07-17: installTap with a format
    /// incompatible with the live route raises an ObjC NSException that Swift's
    /// do/catch cannot trap. Before the fix this was SIGABRT. NutolaTryBlock must
    /// catch it and return the exception instead.
    @Test func testInstallTapNSExceptionIsTrapped() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // An impossible sample rate forces AVAudioNode to raise an NSException
        // on installTap, independent of the current audio route.
        let badFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 999_999,
            channels: 1,
            interleaved: false)!
        let exception = NutolaTryBlock {
            input.installTap(onBus: 0, bufferSize: 1024, format: badFormat) { _, _ in }
        }
        #expect(exception != nil, "NutolaTryBlock should have trapped the NSException, not let it through to SIGABRT")
        if let exception {
            #expect(!(exception.reason ?? "" == ""))
        }
    }
}
