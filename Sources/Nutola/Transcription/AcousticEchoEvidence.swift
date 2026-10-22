import AVFoundation
import Foundation

/// Offline evidence of acoustic playback leaking from the Mac speakers into
/// the microphone. This is NOT a speaker-recognition model and must never
/// be used as the only reason to discard a local utterance.
///
/// We store a 20 ms RMS envelope rather than loading hour-long PCM recordings
/// into memory. Correlation of the envelopes tolerates loudspeaker coloration
/// and small clock offsets between the two independently started recorders.
struct AcousticEchoEvidence: Sendable {
    static let binSeconds: TimeInterval = 0.020

    let microphone: [Float]
    let system: [Float]

    init(microphone: [Float], system: [Float]) {
        self.microphone = microphone
        self.system = system
    }

    static func load(microphoneURL: URL, systemURL: URL) throws -> AcousticEchoEvidence {
        AcousticEchoEvidence(
            microphone: try envelope(of: microphoneURL),
            system: try envelope(of: systemURL)
        )
    }

    /// This deliberately works on bounded memory even for lengthy meetings.
    /// Files are decoded as non-interleaved Float32 by AVAudioFile.
    private static func envelope(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { return [] }

        let samplesPerBin = max(1, Int((format.sampleRate * binSeconds).rounded()))
        let channels = Int(format.channelCount)
        var envelope: [Float] = []
        envelope.reserveCapacity(Int(Double(file.length) / format.sampleRate / binSeconds) + 2)

        var sumSquares = 0.0
        var samples = 0
        while true {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            guard let data = buffer.floatChannelData else { return [] }

            for frame in 0..<frames {
                var power = 0.0
                for channel in 0..<channels {
                    let sample = Double(data[channel][frame])
                    power += sample * sample
                }
                sumSquares += power / Double(channels)
                samples += 1
                if samples == samplesPerBin {
                    envelope.append(Float(sqrt(sumSquares / Double(samples))))
                    samples = 0
                    sumSquares = 0
                }
            }
        }
        if samples > 0 {
            envelope.append(Float(sqrt(sumSquares / Double(samples))))
        }
        return envelope
    }

    /// Looks for matching temporal energy patterns with up to ±1 s alignment
    /// error (the two recorders may start at slightly different times).
    /// Returns nil when an interval is too short, quiet or lacks sufficient
    /// samples; nil is *not* evidence that the local speaker is genuine.
    func bestCorrelation(start: TimeInterval, end: TimeInterval) -> Double? {
        let from = max(0, Int(floor(start / Self.binSeconds)))
        let to = min(microphone.count, Int(ceil(end / Self.binSeconds)))
        guard to - from >= 35 else { return nil } // >=700 ms
        let length = to - from

        var best = -1.0
        let maxShift = Int(1.0 / Self.binSeconds)
        for shift in -maxShift...maxShift {
            let left = max(from, -shift)
            let right = min(to, system.count - shift)
            let count = right - left
            // Reject short intersections near start/end of the recordings.
            guard count >= 35, Double(count) / Double(length) >= 0.85 else { continue }

            var sumMic = 0.0
            var sumSys = 0.0
            var sumMM = 0.0
            var sumSS = 0.0
            var sumMS = 0.0

            for index in left..<right {
                let m = Double(microphone[index])
                let s = Double(system[index + shift])
                sumMic += m
                sumSys += s
                sumMM += m * m
                sumSS += s * s
                sumMS += m * s
            }

            let n = Double(count)
            // Both sources must have audible energy, not correlated silence.
            guard sumMic / n > 0.0007, sumSys / n > 0.0007 else { continue }
            let mVariance = sumMM - sumMic * sumMic / n
            let sVariance = sumSS - sumSys * sumSys / n
            guard mVariance > 1e-8, sVariance > 1e-8 else { continue }
            let covariance = sumMS - sumMic * sumSys / n
            best = max(best, covariance / sqrt(mVariance * sVariance))
        }

        return best >= 0 ? best : nil
    }

    /// A deliberately high threshold: correlation alone cannot distinguish
    /// overlap between a local voice and a remote voice from pure acoustic echo.
    func stronglyMatches(start: TimeInterval, end: TimeInterval) -> Bool {
        guard let score = bestCorrelation(start: start, end: end) else { return false }
        return score >= 0.82
    }
}
