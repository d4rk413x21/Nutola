import Accelerate
import AVFoundation
import CoreAudio

enum SystemAudioTapError: LocalizedError {
    case alreadyRunning
    case coreAudio(OSStatus, String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "System audio capture is already running."
        case .coreAudio(let status, let call):
            return "System audio capture failed: \(call) returned \(status)."
        case .unsupportedFormat:
            return "The system audio tap produced an unsupported stream format."
        }
    }
}

private func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw SystemAudioTapError.coreAudio(status, call) }
}

/// Records all other apps' audio to an AAC .m4a via a Core Audio process tap.
/// Requires NSAudioCaptureUsageDescription in Info.plist; the "System Audio Recording
/// Only" TCC prompt fires on the first AudioDeviceStart. Denied/ungranted permission
/// does not produce errors — IO just delivers silence.
final class SystemAudioTap: @unchecked Sendable {
    private(set) var isRunning = false

    /// Serializes start/stop and device-change rebuilds; also the listener dispatch queue.
    private let controlQueue = DispatchQueue(label: "nutola.system-tap.control")
    /// IOProc dispatch queue — macOS 26 silently ignores the block when passed nil.
    /// All AVAudioFile writes (and finalization) are confined here.
    private let ioQueue = DispatchQueue(label: "nutola.system-tap.io", qos: .userInitiated)

    struct CaptureStats: Sendable {
        var callbackCount = 0
        var framesWritten: UInt64 = 0
        var peakLevel: Float = 0
        var receivedAnyCallback = false
    }

    private(set) var captureStats = CaptureStats()
    private var writeFailure = AudioWriteFailure()
    var writeError: String? { ioQueue.sync { writeFailure.message } }

    /// Current IO callback count — read by the RecordingSession watchdog to
    /// detect a stalled tap (callbacks stopped but isRunning still true) and
    /// trigger a rebuild.
    var currentCallbackCount: UInt64 {
        controlQueue.sync { ioQueue.sync { UInt64(captureStats.callbackCount) } }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    /// Mutated only from controlQueue via ioQueue.sync; read freely on either queue.
    private var file: AVAudioFile?

    /// Session start in host-clock ticks. With tapautostart the first IO callback
    /// arrives only once some app plays sound, so the file would otherwise begin at
    /// "first sound" while mic.m4a begins at t=0 — mis-aligning the merged transcript.
    /// We pad the file with leading silence to close that gap. (ioQueue only.)
    private var anchorHostTime: UInt64 = 0
    private var didAnchor = false

    /// Fires once, off the ioQueue, the first time the tap delivers non-silent audio — the
    /// only reliable evidence macOS granted System Audio Recording (there is no TCC preflight,
    /// and neither tap creation nor AudioDeviceStart fails on denial; a denied grant runs this
    /// same IO path with zeroed buffers). Assign before start(). (ioQueue only after that.)
    var signalDetectedHandler: (@Sendable () -> Void)?
    private var didSignalSuccess = false

    /// Peak from the last few seconds of system tap IO — proxy for remote speech.
    var recentSystemPeak: Float {
        controlQueue.sync { ioQueue.sync { recentPeakWithinWindow() } }
    }

    private var lastRemotePeak: Float = 0
    private var lastRemotePeakHostTime: UInt64 = 0
    private static let remotePeakMemory: Double = 3.0

    /// True once the tap has delivered non-silent audio this session (proof the TCC grant is real).
    var signalDetected: Bool {
        controlQueue.sync { ioQueue.sync { didSignalSuccess } }
    }

    private func recentPeakWithinWindow() -> Float {
        guard lastRemotePeakHostTime > 0 else { return 0 }
        let elapsed = Double(mach_absolute_time() - lastRemotePeakHostTime) / Self.ticksPerSecond
        return elapsed <= Self.remotePeakMemory ? lastRemotePeak : 0
    }

    /// Fork of each captured buffer for live transcription. Assign before start().
    /// The sink deep-copies immediately — the buffer is only valid during this
    /// IO callback. (ioQueue after start; set once before start, like the handler above.)
    var bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    func start(writingTo url: URL) throws {
        try controlQueue.sync {
            guard !isRunning else { throw SystemAudioTapError.alreadyRunning }
            captureStats = CaptureStats()
            didSignalSuccess = false
            do {
                let tap = try createTap()
                let file = try makeFile(at: url, tapFormat: tap.format)
                let outputName = Self.defaultOutputDeviceName() ?? "unknown"
                NutolaConsoleLog.recording(
                    "system tap creating output=[\(outputName)] tapSr=\(tap.format.sampleRate) tapCh=\(tap.format.channelCount)")
                ioQueue.sync {
                    self.file = file
                    self.anchorHostTime = mach_absolute_time()
                    self.didAnchor = false
                }
                try createAggregateAndStartIO(tapUID: tap.uid, tapFormat: tap.format, file: file)
                try installOutputDeviceListener()
                isRunning = true
                NutolaConsoleLog.recording("system tap started")
            } catch {
                NutolaConsoleLog.recording("system tap start failed — \(error.localizedDescription)")
                removeOutputDeviceListener()
                teardownCapture()
                ioQueue.sync { self.file = nil }
                throw error
            }
        }
    }

    func stop() {
        controlQueue.sync {
            guard isRunning else { return }
            let (stats, signal) = ioQueue.sync { (captureStats, didSignalSuccess) }
            NutolaConsoleLog.recording(
                "system tap stop callbacks=\(stats.callbackCount) frames=\(stats.framesWritten)"
                    + " peak=\(String(format: "%.4f", stats.peakLevel)) signal=\(signal)")
            isRunning = false
            removeOutputDeviceListener()
            teardownCapture()
            // Drains any queued IO writes, then finalizes the m4a.
            ioQueue.sync { self.file = nil }
        }
    }

    deinit { stop() }

    // MARK: - Pipeline (controlQueue)

    private func createTap() throws -> (uid: String, format: AVAudioFormat) {
        // Exclude lists take HAL process OBJECT IDs, not pids; translation yields
        // kAudioObjectUnknown when we have never been a HAL client — exclude nothing then.
        var excluded: [AudioObjectID] = []
        let own = try Self.processObject(forPID: getpid())
        if own != kAudioObjectUnknown { excluded.append(own) }

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Nutola System Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        var asbd = try Self.tapStreamFormat(tap)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioTapError.unsupportedFormat
        }
        return (description.uuid.uuidString, format)
    }

    private func makeFile(at url: URL, tapFormat: AVAudioFormat) throws -> AVAudioFile {
        // Apple's AAC encoder tops out at 48 kHz, and AVAudioFile encodes but never
        // resamples — cap the file rate and convert on the way in when the tap runs faster.
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(tapFormat.sampleRate, 48_000),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: tapFormat.isInterleaved)
    }

    private func createAggregateAndStartIO(
        tapUID: String, tapFormat: AVAudioFormat, file: AVAudioFile
    ) throws {
        let converter: AVAudioConverter?
        if tapFormat == file.processingFormat {
            converter = nil
        } else if let made = AVAudioConverter(from: tapFormat, to: file.processingFormat) {
            converter = made
        } else {
            throw SystemAudioTapError.unsupportedFormat
        }

        let outputUID = try Self.defaultOutputDeviceUID()
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName(pid: getpid()),
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice")

        // Tap audio arrives as the aggregate's input buffers. Format and converter are
        // baked into this IOProc's block so a rebuild can never mix formats mid-buffer.
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, _, _ in
            self?.writeInput(inInputData, inputTime: inInputTime, format: tapFormat, converter: converter)
        }
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, ioBlock),
            "AudioDeviceCreateIOProcIDWithBlock")

        // With tapautostart, callbacks begin only once a tapped process emits audio.
        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    /// Order matters (HAL objects leak or wedge otherwise):
    /// stop -> destroy IOProc -> destroy aggregate -> destroy tap. Leaves the file open.
    private func teardownCapture() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Default output device changes

    private func installOutputDeviceListener() throws {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildForNewOutputDevice()
        }
        try check(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener),
            "AudioObjectAddPropertyListenerBlock")
        outputDeviceListener = listener
    }

    private func removeOutputDeviceListener() {
        guard let listener = outputDeviceListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        outputDeviceListener = nil
    }

    /// Rebuild the tap+aggregate against the current default output device.
    /// Called by the output-device listener and by the RecordingSession
    /// watchdog when callbacks stall (the tap died but isRunning is still true).
    func rebuildCapture() {
        rebuildForNewOutputDevice()
    }

    /// The tap format is frozen at creation, so a new default output device means the
    /// old aggregate keeps the stale clock. Rebuild tap+aggregate+IOProc against the
    /// same open file; the per-build converter bridges any new tap format into the
    /// file's processing format so one continuous recording keeps growing.
    private func rebuildForNewOutputDevice() {
        guard isRunning, let file else { return }
        let outputName = Self.defaultOutputDeviceName() ?? "unknown"
        NutolaConsoleLog.recording("system tap rebuilding for new output=[\(outputName)]")
        teardownCapture()
        do {
            let tap = try createTap()
            try createAggregateAndStartIO(tapUID: tap.uid, tapFormat: tap.format, file: file)
            NutolaConsoleLog.recording("system tap rebuild OK output=[\(outputName)]")
        } catch {
            NutolaConsoleLog.recording("system tap rebuild failed — \(error.localizedDescription)")
            // Capture is dead, but keep the file open so stop() still finalizes
            // everything recorded so far. A later device change retries the rebuild.
            teardownCapture()
        }
    }

    // MARK: - Writing (ioQueue)

    private func writeInput(
        _ list: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        format: AVAudioFormat,
        converter: AVAudioConverter?
    ) {
        guard let file,
              let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
              input.frameLength > 0
        else { return }

        captureStats.callbackCount += 1
        captureStats.framesWritten += UInt64(input.frameLength)
        if let samples = input.floatChannelData?[0] {
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(input.frameLength))
            captureStats.peakLevel = max(captureStats.peakLevel, peak)
            if peak >= 0.015 {
                lastRemotePeak = max(lastRemotePeak, peak)
                lastRemotePeakHostTime = mach_absolute_time()
            }
        }
        let logFirst = !captureStats.receivedAnyCallback
        if logFirst { captureStats.receivedAnyCallback = true }
        let logHeartbeat = captureStats.callbackCount % 500 == 0
        let callbackPeak = captureStats.peakLevel
        let callbackCount = captureStats.callbackCount

        // Fork to the live transcriber (it deep-copies before this callback returns).
        bufferSink?(input)

        // Proof of the TCC grant: real audio (even a quiet room) isn't exact digital zero,
        // whereas a denied grant hands back all-zero buffers on this same path.
        if !didSignalSuccess, Self.containsSignal(input) {
            didSignalSuccess = true
            NutolaConsoleLog.recording(
                "system tap signal detected peak=\(String(format: "%.4f", callbackPeak)) callbacks=\(callbackCount)")
            signalDetectedHandler?()
        } else if logFirst {
            NutolaConsoleLog.recording(
                "system tap first callback frames=\(input.frameLength) peak=\(String(format: "%.4f", callbackPeak)) silent=\(!Self.containsSignal(input))")
        } else if logHeartbeat {
            NutolaConsoleLog.recording(
                "system tap heartbeat callbacks=\(callbackCount) peak=\(String(format: "%.4f", callbackPeak)) signal=\(didSignalSuccess)")
        }

        // On the first real buffer, pad the file so its t=0 is recording start,
        // not first-sound. Uses the buffer's host time vs the session anchor.
        if !didAnchor {
            didAnchor = true
            let stamp = inputTime.pointee
            if stamp.mFlags.contains(.hostTimeValid), stamp.mHostTime > anchorHostTime {
                let gap = Double(stamp.mHostTime - anchorHostTime) / Self.ticksPerSecond
                writeSilence(seconds: min(gap, 3600), to: file)
            }
        }

        do {
            guard let converter else {
                try file.write(from: input)
                return
            }
            let ratio = file.processingFormat.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
            else { return }
            var consumed = false
            var conversionError: NSError?
            // .noDataNow (not .endOfStream) keeps the resampler primed across callbacks.
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
            if status != .error, output.frameLength > 0 {
                try file.write(from: output)
            }
        } catch {
            writeFailure.record(error, source: "System")
        }
    }

    /// Peak magnitude above a tiny epsilon (not an RMS floor) — we only need yes/no, and a
    /// denied grant's buffers are exactly zero, not merely quiet.
    private static func containsSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(buffer.frameLength))
        return peak > 0.005
    }

    /// Writes `seconds` of silence to the file in the file's processing format,
    /// in ~1s chunks. Called once, before the first real buffer.
    private func writeSilence(seconds: Double, to file: AVAudioFile) {
        let sampleRate = file.processingFormat.sampleRate
        var remaining = Int((seconds * sampleRate).rounded())
        let chunk = Int(sampleRate)
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(chunk, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
            else { return }
            buffer.frameLength = frames
            if let channels = buffer.floatChannelData {
                for ch in 0..<Int(file.processingFormat.channelCount) {
                    memset(channels[ch], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }
            do { try file.write(from: buffer) }
            catch {
                writeFailure.record(error, source: "System")
                return
            }
            remaining -= Int(frames)
        }
    }

    // MARK: - Orphan cleanup

    private static let aggregateNamePrefix = "Nutola Tap Aggregate"
    /// The aggregate name carries its creating pid so a later launch can tell a genuine orphan
    /// (creator process dead) from a live sibling instance's device (creator alive). There is NO
    /// single-instance enforcement in this app, and AudioHardwareDestroyAggregateDevice isn't
    /// scoped to the creating process — matching the bare name alone would let one instance
    /// destroy another's live recording, or a user's identically-named Audio MIDI Setup device.
    private static func aggregateName(pid: pid_t) -> String { "\(aggregateNamePrefix) (pid \(pid))" }

    /// Destroys any Nutola tap aggregate left behind by a previous process that crashed or was
    /// force-killed (SIGKILL) mid-recording — graceful termination tears its own down via stop().
    /// A leaked aggregate keeps its tap running, so macOS shows the "System Audio Recording"
    /// indicator with nothing recording. Best-effort; safe to call any time (never touches a
    /// device whose creator is still alive).
    static func destroyLeftoverAggregates() {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return }
        for device in devices where isLeftoverAggregate(device) {
            AudioHardwareDestroyAggregateDevice(device)
        }
    }

    /// True only for an aggregate this app created (name prefix + embedded pid) whose creating
    /// process is no longer alive — never our own, never a live sibling's, never a user device.
    private static func isLeftoverAggregate(_ device: AudioObjectID) -> Bool {
        guard deviceTransport(device) == kAudioDeviceTransportTypeAggregate,
              let name = deviceName(device),
              let pid = creatorPID(fromName: name),
              pid != getpid()
        else { return false }
        return !processIsAlive(pid)
    }

    private static func creatorPID(fromName name: String) -> pid_t? {
        let prefix = aggregateNamePrefix + " (pid "
        guard name.hasPrefix(prefix), name.hasSuffix(")") else { return nil }
        return pid_t(name.dropFirst(prefix.count).dropLast())
    }

    /// A signal-0 kill probes existence without delivering anything: 0 = alive; EPERM = alive
    /// (exists, not ours to signal); ESRCH = no such process. Only ESRCH counts as dead, so a
    /// transient/permission error never green-lights destroying a live device.
    private static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func deviceTransport(_ device: AudioObjectID) -> UInt32? {
        var addr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let ok = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, pointer) == noErr
        }
        return ok ? (name as String) : nil
    }

    // MARK: - HAL helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Returns kAudioObjectUnknown (not an error) when the pid has no HAL client object.
    private static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.stride), &qualifier, &size, &object),
            "kAudioHardwarePropertyTranslatePIDToProcessObject")
        return object
    }

    private static func tapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        try check(
            AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd),
            "kAudioTapPropertyFormat")
        return asbd
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID),
            "kAudioHardwarePropertyDefaultOutputDevice")
        var uidAddr = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.stride)
        try withUnsafeMutablePointer(to: &uid) { pointer in
            try check(
                AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, pointer),
                "kAudioDevicePropertyDeviceUID")
        }
        return uid as String
    }

    private static func defaultOutputDeviceName() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceName(deviceID)
    }
}
