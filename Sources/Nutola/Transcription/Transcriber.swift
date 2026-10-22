import AVFoundation
import CoreMedia
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case modelUnavailable
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let identifier):
            return "Transcription isn't available for the language “\(identifier)”."
        case .modelUnavailable:
            return "On-device transcription isn't supported on this Mac."
        case .emptyAudio:
            return "The recording contains no audio."
        }
    }
}

enum Transcriber {
    static func modelInstalled() async -> Bool {
        await TranscriptionLocales.modelsInstalled()
    }

    enum EngineDecision: Equatable {
        case apple
        case parakeet(TranscriptionModel)
    }

    static func resolveEngine(for selected: TranscriptionModel? = nil) -> EngineDecision {
        let model = selected ?? AppSettings.transcriptionModel
        switch model {
        case .apple:
            return .apple
        case .parakeetRedux, .parakeetUltra:
            return .parakeet(model)
        }
    }

    static func ensureModel(
        progress: (@Sendable (Double) -> Void)?,
        selected: TranscriptionModel? = nil
    ) async throws {
        let model = selected ?? AppSettings.transcriptionModel
        if model == .apple {
            try await TranscriptionLocales.ensureModels(progress: progress)
        } else {
            try await FluidParakeetModels.download(model)
            progress?(1)
        }
    }

    static func transcribeFile(at url: URL) async throws -> TranscriptionOutput {
        try await transcribeFile(at: url, selected: AppSettings.transcriptionModel, locale: nil)
    }

    static func transcribeFile(
        at url: URL,
        selected: TranscriptionModel?,
        locale: Locale? = nil
    ) async throws -> TranscriptionOutput {
        switch resolveEngine(for: selected) {
        case .apple:
            return try await transcribeWithApple(at: url, locale: locale)
        case .parakeet(let model):
            // Do not silently claim a Parakeet transcription if it failed.
            return try await FluidParakeetTranscriber.transcribeFile(at: url, model: model)
        }
    }

    /// The Apple SpeechAnalyzer batch path — the wired inference engine today.
    private static func transcribeWithApple(at url: URL, locale: Locale?) async throws -> TranscriptionOutput {
        NutolaConsoleLog.transcribe("file \(url.lastPathComponent)")
        let transcriber = try await makeTranscriber(locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])
        else {
            throw TranscriberError.modelUnavailable
        }

        // Results must be consumed concurrently: the stream only terminates when the
        // session finishes, so awaiting it before feeding audio would deadlock.
        async let collected = collectResults(from: transcriber)

        let audioFile = try await openReadableAudioFile(at: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feedTask = Task {
            defer { inputContinuation.finish() }
            await feedAudioFile(audioFile, to: inputContinuation, analyzerFormat: analyzerFormat)
        }

        guard let lastSampleTime = try await analyzer.analyzeSequence(inputStream) else {
            await analyzer.cancelAndFinishNow()
            feedTask.cancel()
            _ = await feedTask.value
            throw TranscriberError.emptyAudio
        }
        // analyzeSequence returns when the file is read, not when analysis is done;
        // without this the results stream never terminates.
        try await analyzer.finalizeAndFinish(through: lastSampleTime)
        _ = await feedTask.value

        let (segments, words) = try await collected
        NutolaConsoleLog.transcribe("\(url.lastPathComponent) → \(segments.count) segments, \(words.count) words")
        return TranscriptionOutput(words: words.isEmpty ? segments : words, segments: segments)
    }

    /// Opens a finalized recording. AAC writers can take a beat to flush after stop(),
    /// so a few short retries avoid spurious `dta?` / invalid-file errors.
    private static func openReadableAudioFile(at url: URL) async throws -> AVAudioFile {
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0 else { throw TranscriberError.emptyAudio }
                return file
            } catch let error as TranscriberError {
                throw error
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(25 * (attempt + 1)))
            }
        }
        throw lastError ?? TranscriberError.emptyAudio
    }

    /// Decodes the `.m4a` to PCM and converts to the analyzer's preferred format — the
    /// same path the live transcriber uses. `analyzeSequence(from:)` rejects our AAC
    /// container with avfaudio `dta?` even though the file plays fine elsewhere.
    private static func feedAudioFile(
        _ file: AVAudioFile,
        to continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat
    ) async {
        let inputFormat = file.processingFormat
        var converter: AVAudioConverter?
        if inputFormat != analyzerFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            converter?.primeMethod = .none
        }

        let chunkFrames: AVAudioFrameCount = 8192
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames)
        else { return }

        while file.framePosition < file.length {
            readBuffer.frameLength = 0
            do {
                try file.read(into: readBuffer)
            } catch {
                NutolaConsoleLog.transcribe("read failed — \(error.localizedDescription)")
                return
            }
            guard readBuffer.frameLength > 0 else { break }

            if let converter, let converted = LiveTranscriber.convert(
                readBuffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            } else if let copy = LiveTranscriber.copy(readBuffer) {
                continuation.yield(AnalyzerInput(buffer: copy))
            }
        }
    }

    private static func makeTranscriber(locale: Locale?) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.modelUnavailable }
        let pinned: Locale?
        if let locale {
            pinned = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        } else {
            pinned = nil
        }
        let resolved: Locale?
        if let pinned {
            resolved = pinned
        } else {
            resolved = await TranscriptionLocales.primary()
        }
        guard let resolved else {
            throw TranscriberError.unsupportedLocale(Locale.current.identifier)
        }
        NutolaConsoleLog.locales("batch locale → \(resolved.identifier(.bcp47))")
        // Batch mode: no .volatileResults, so every result arrives final exactly once.
        return SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> (segments: [TranscribedWord], words: [TranscribedWord]) {
        var segments: [TranscribedWord] = []
        var words: [TranscribedWord] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(TranscribedWord(
                text: text,
                start: result.range.start.seconds,
                end: result.range.end.seconds
            ))
            for run in result.text.runs {
                // Runs without timing (punctuation, whitespace) are skipped; segments
                // remain the fallback when no run carries a time range.
                guard let timeRange = run.audioTimeRange else { continue }
                let word = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                words.append(TranscribedWord(
                    text: word,
                    start: timeRange.start.seconds,
                    end: timeRange.end.seconds
                ))
            }
        }
        return (segments, words)
    }
}
