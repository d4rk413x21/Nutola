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

    /// Which ASR engine the pipeline should actually run for a given selection.
    ///
    /// The selection is a pure, side-effect-free decision: it inspects the model
    /// files on disk and the availability of the wired inference engine, then
    /// reports what the pipeline should do. Callers branch on the result and log
    /// a clear message on fallback. Keeping the decision separate from the async
    /// audio path lets tests verify model selection without real audio.
    enum EngineDecision: Equatable {
        /// Use the Apple SpeechAnalyzer / SpeechTranscriber path.
        case apple
        /// A Soniqo Parakeet CoreML model is downloaded, but Nutola has not wired its
        /// inference engine yet — fall back to Apple with an explanatory log.
        case parakeetInstalledButNoInference(TranscriptionModel)
        /// The Parakeet model is selected but its weights aren't on disk (and no
        /// inference engine is wired either) — fall back to Apple. Distinct from
        /// `parakeetInstalledButNoInference` so the log and tests can tell whether
        /// the user's download actually landed.
        case parakeetNotInstalled(TranscriptionModel)
        /// Nemotron weights can be downloaded but the inference runner is not wired
        /// yet — fall back to Apple with an explanatory log.
        case nemotronNotAvailable
    }

    /// Resolves which engine a transcription should run for the user's selected
    /// model. Apple is always available on supported hardware; the downloadable
    /// engines require their weights on disk *and* an inference engine wired into
    /// Nutola. Today only Apple's path is wired, so Parakeet/Nemotron selections
    /// report their fallback reason here rather than in the audio hot path.
    ///
    /// `selected` defaults to `AppSettings.transcriptionModel` so the production
    /// pipeline branches on the user's Settings choice; tests pass an explicit
    /// model to assert each branch without touching UserDefaults or audio.
    static func resolveEngine(for selected: TranscriptionModel? = nil) -> EngineDecision {
        let model = selected ?? AppSettings.transcriptionModel
        switch model {
        case .apple:
            return .apple
        case .parakeetStreaming, .parakeetBatch:
            // The CoreML weights live under Application Support and are checked
            // for real (see TranscriptionModel.isModelInstalled). In both cases
            // we fall back to Apple — Nutola has no Parakeet inference engine
            // wired yet (SoniqoModelStore manages bytes only) — but the decision
            // distinguishes whether the user's download landed, so the log and
            // tests can confirm the real model-file check happened.
            return model.isModelInstalled
                ? .parakeetInstalledButNoInference(model)
                : .parakeetNotInstalled(model)
        case .nemotron:
            return .nemotronNotAvailable
        }
    }

    /// Ensures the model for the user's selected engine is available, then the
    /// Apple fallback (which is what actually runs today). Passing `selected`
    /// makes the model choice injectable for tests.
    static func ensureModel(
        progress: (@Sendable (Double) -> Void)?,
        selected: TranscriptionModel? = nil
    ) async throws {
        let model = selected ?? AppSettings.transcriptionModel

        // Ensure the selected model's weights are on disk when Nutola's inference
        // engine for them ships. Today the engines aren't wired, so the download
        // is only meaningful once they are — but honoring the selection keeps the
        // `ensure` contract honest (the user asked for this model).
        if model.isDownloadable, !model.isModelInstalled {
            do {
                try await model.downloadModel(progress: { fraction in
                    progress?(fraction)
                })
            } catch {
                // A failed download must not block transcription — Apple is the
                // fallback and only needs its on-device assets, ensured below.
                model.logModelEvent("download failed — \(error.localizedDescription); falling back to Apple")
            }
        }

        // Apple is the wired fallback for every engine today, so its assets must
        // be present regardless of the selection.
        try await TranscriptionLocales.ensureModels(progress: progress)
    }

    /// Back-compat entry point used by `ProcessingPipeline` and existing tests.
    /// Branches on the user's selected transcription model (AppSettings).
    static func transcribeFile(at url: URL) async throws -> TranscriptionOutput {
        try await transcribeFile(at: url, selected: AppSettings.transcriptionModel, locale: nil)
    }

    /// Transcribes a file using the selected engine, falling back to Apple's
    /// SpeechAnalyzer when the selected engine's inference isn't wired.
    static func transcribeFile(
        at url: URL,
        selected: TranscriptionModel?,
        locale: Locale? = nil
    ) async throws -> TranscriptionOutput {
        let model = selected ?? AppSettings.transcriptionModel
        let decision = resolveEngine(for: model)
        switch decision {
        case .apple:
            return try await transcribeWithApple(at: url, locale: locale)
        case .parakeetInstalledButNoInference(let selected):
            // The weights are on disk, but Nutola has no Parakeet inference engine
            // wired yet (SoniqoModelStore manages bytes only). Fall back to Apple
            // rather than fail the whole meeting.
            NutolaConsoleLog.soniqo(
                "Parakeet model selected but inference not available — falling back to Apple Speech"
                + " (\(selected.rawValue))")
            NutolaConsoleLog.transcribe(
                "file \(url.lastPathComponent) via Apple (fallback from \(selected.rawValue))")
            return try await transcribeWithApple(at: url, locale: locale)
        case .parakeetNotInstalled(let selected):
            // No weights on disk and no inference engine wired — the user hasn't
            // downloaded the model (or the download failed). Fall back to Apple.
            NutolaConsoleLog.soniqo(
                "Parakeet model selected (\(selected.rawValue)) but not installed — falling back to Apple Speech")
            NutolaConsoleLog.transcribe(
                "file \(url.lastPathComponent) via Apple (fallback from \(selected.rawValue), not installed)")
            return try await transcribeWithApple(at: url, locale: locale)
        case .nemotronNotAvailable:
            NutolaConsoleLog.nemotron(
                "Nemotron engine not yet available — falling back to Apple Speech")
            NutolaConsoleLog.transcribe(
                "file \(url.lastPathComponent) via Apple (fallback from nemotron)")
            return try await transcribeWithApple(at: url, locale: locale)
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
