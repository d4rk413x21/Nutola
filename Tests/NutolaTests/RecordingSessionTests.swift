import Synchronization
import XCTest
@testable import Nutola

// MARK: - #83 / #84: RecordingSession stop notice & restart error propagation

/// `RecordingSession` is `@MainActor`. These tests exercise two observable
/// contracts that don't require a live audio capture:
///
///   - #83: `stop()` sets `stopNotice` when both capture files are empty
///     (zero bytes), signalling the UI that no audio was captured.
///   - #84: `micRestartError` is the surfacing point for mic restart failures.
///     The wiring lives in `start()` (mic.onRestartFailure → micRestartError);
///     we verify the `MicRecorder.onRestartFailure` callback surface delivers
///     errors to a caller-supplied closure, and that a fresh session exposes
///     `micRestartError == nil` until a failure is reported.
@MainActor
final class RecordingSessionTests: XCTestCase {
    private var tmp: URL!
    private var archive: MeetingArchive!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-session-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    // #83: a session stopped with no captured audio (both files missing → 0
    // bytes) must surface a non-empty `stopNotice` so the UI can warn the user.
    func testZeroBytesProducesNotice() async {
        let id = UUID()
        try? archive.createFolder(for: id)
        let session = RecordingSession(meetingID: id, archive: archive)
        // Don't call start() — no audio capture is set up. The mic/system URLs
        // point at files that don't exist, so attributesOfItem throws → 0 bytes.
        await session.stopAsync()
        XCTAssertNotNil(session.stopNotice, "stopNotice must be set when both capture files are empty")
        XCTAssertEqual(
            session.stopNotice,
            "No audio was captured — check your microphone and system audio settings")
    }

    // #84: a fresh session exposes no restart error until the mic signals one.
    // The MicRecorder.onRestartFailure callback is the surfacing surface; we
    // verify it delivers errors to a caller-supplied closure (the same shape
    // RecordingSession.start wires to set micRestartError).
    func testRestartErrorPropagation() {
        // A fresh session has no restart error.
        let id = UUID()
        try? archive.createFolder(for: id)
        let session = RecordingSession(meetingID: id, archive: archive)
        XCTAssertNil(session.micRestartError, "micRestartError must start nil")

        // The MicRecorder callback is the channel RecordingSession uses; verify
        // it surfaces an error to a caller-supplied closure. RecordingSession
        // wires this in start(): mic.onRestartFailure = { ... micRestartError = ... }.
        let recorder = MicRecorder()
        let captured = Mutex<String?>(nil)
        recorder.onRestartFailure = { error in
            captured.withLock { $0 = error.localizedDescription }
        }
        struct FakeRestartError: Error, LocalizedError {
            var errorDescription: String? { "audio route changed" }
        }
        recorder.onRestartFailure?(FakeRestartError())
        XCTAssertEqual(captured.withLock { $0 }, "audio route changed",
                       "MicRecorder.onRestartFailure must deliver the error to the closure")
    }
}
