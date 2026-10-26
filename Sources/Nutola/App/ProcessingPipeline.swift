import AVFoundation
import Foundation

/// Post-recording pipeline: transcribe both channels → identify speakers →
/// label segments → summarize + title. Pure orchestration; every stage is
/// resilient — a meeting with any transcript at all ends up .ready.
enum ProcessingPipeline {
    /// Everything the pipeline is allowed to change on a meeting. AppState
    /// merges this onto a FRESH copy of the meeting, so user edits made during
    /// the (minutes-long) run are never clobbered by a stale snapshot.
    struct Outcome: Sendable {
        var state: MeetingState
        var notice: String?
        var speakers: [Speaker]?
        var platformSpeakerAttribution: Bool = false
        var summaryProvider: String?
        var generatedTitle: String?
    }

    /// Progressive summary signal for the UI. The draft streams in seconds after
    /// Stop; the improvement replaces it once the accurate transcript is ready.
    enum SummaryUpdate: Sendable {
        /// Growing markdown of the pass currently streaming (draft, or the sole pass
        /// when there is no live transcript). May be empty at the very start.
        case streaming(String)
        /// A draft is saved; an improvement pass will follow (badge: "Draft · improving").
        case draftSaved
        /// The progressive phase is over — the UI should read the saved summary.
        case done
    }

    /// Shared locale-aware formatter for one-decimal second values in log strings,
    /// replacing `String(format: "%.1f", …)` which ignores the user's locale.
    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    /// Formats a speaker turn's range as `"name 12.3-45.6"`, locale-aware.
    private static func formatTurnRange(speaker: String, start: TimeInterval, end: TimeInterval) -> String {
        let s = decimalFormatter.string(from: NSNumber(value: start)) ?? "\(start)"
        let e = decimalFormatter.string(from: NSNumber(value: end)) ?? "\(end)"
        return "\(speaker) \(s)-\(e)"
    }

    static func run(
        meeting: Meeting,
        archive: MeetingArchive,
        onProgress: @escaping @Sendable (String) -> Void,
        onSummary: @escaping @Sendable (SummaryUpdate) -> Void = { _ in }
    ) async -> Outcome {
        let id = meeting.id
        let storedTranscript = archive.transcript(for: id)
        let liveSegments = archive.liveTranscript(for: id)
        // ProcessingUseCase preserves the live draft in transcript.json before
        // starting ASR. It is provisional, NOT a previous recording. Remove
        // only an exact shifted suffix, so final ASR replaces rather than
        // duplicates it; earlier sessions and user-edited turns remain intact.
        let priorSegments = Self.priorSegmentsExcludingPromotedLive(
            storedTranscript, live: liveSegments)
        let appendOffset = Self.appendOffset(meeting: meeting, prior: priorSegments)
        let micURL = archive.micURL(for: id)
        let systemURL = archive.systemURL(for: id)
        let hasMic = Self.hasUsableAudio(at: micURL)
        let hasSystem = Self.hasUsableAudio(at: systemURL)
        if !hasSystem && FileManager.default.fileExists(atPath: systemURL.path) {
            NutolaConsoleLog.pipeline(
                "system audio has no decodable samples (recording may have contained no playback); skipping ASR and diarization")
        }
        var notices: [String] = meeting.notice.map { [$0] } ?? []
        var outcome = Outcome(state: .ready)

        // 0. Draft the notes from the live transcript first, so they appear seconds
        //    after Stop (streamed token by token) while the accurate transcript is
        //    still being built. A failed draft just falls through to the batch pass.
        NutolaConsoleLog.pipeline(
            "run meeting=\(id.uuidString.prefix(8)) title=\"\(meeting.title)\" mic=\(hasMic) system=\(hasSystem)"
                + " live=\(liveSegments.count) prior=\(priorSegments.count) duration=\(Int(meeting.duration))s")
        let liveText = TranscriptFormatter.plainText(liveSegments, speakers: LiveTranscriber.speakers)
        let priorText = priorSegments.isEmpty
            ? ""
            : TranscriptFormatter.plainText(priorSegments, speakers: meeting.speakers)
        let draftInput = [priorText, liveText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var draft: (text: String, provider: String)?
        var expectedSummary = archive.summary(for: id)
        let userNotes = archive.sideNotes(for: id)
        if !draftInput.isEmpty {
            NutolaConsoleLog.pipeline("drafting from live transcript (\(draftInput.count) chars)")
            onSummary(.streaming(""))
            switch await summarize(
                meeting: meeting, transcript: draftInput, userNotes: userNotes,
                onDelta: { onSummary(.streaming($0)) }) {
            case .success(let text, let provider):
                // Only treat the draft as real if it actually persisted. If the write
                // fails, leaving `draft` nil lets the improvement pass save normally
                // rather than the edit-guard (disk == draft.text) blocking it too.
                do {
                    try archive.saveSummary(text, for: id, replacing: expectedSummary)
                    expectedSummary = text
                    draft = (text, provider)
                    outcome.summaryProvider = provider
                    onSummary(.draftSaved)
                    NutolaConsoleLog.pipeline("draft saved via \(provider) (\(text.count) chars)")
                } catch MeetingArchive.ArchiveError.summaryChanged {
                    onSummary(.done)
                } catch {
                    expectedSummary = text
                    NutolaConsoleLog.pipeline("draft save failed — \(error.localizedDescription)")
                    onSummary(.done)
                }
            case .failure:
                NutolaConsoleLog.pipeline("draft summarization failed")
                // No draft — clear the transient streaming UI so it doesn't linger
                // through transcription; the batch pass will write the notes.
                onSummary(.done)
            }
        }

        // 1. Transcribe. Honor the locale chosen for this meeting, even
        // if it differs from the system language used by the batch pipeline.
        let meetingLocale = TranscriptionLocales.storedLocale(forMeetingID: id, root: archive.root)
        onProgress("Preparing speech model…")
        try? await Transcriber.ensureModel(progress: { fraction in
            onProgress("Downloading speech model… \(Int(fraction * 100))%")
        })

        var micOut: TranscriptionOutput?
        var systemOut: TranscriptionOutput?
        if hasMic {
            onProgress("Transcribing your microphone…")
            do {
                micOut = try await Transcriber.transcribeFile(
                    at: micURL, selected: AppSettings.transcriptionModel, locale: meetingLocale)
            } catch {
                NutolaConsoleLog.pipeline("mic batch ASR unavailable — \(error.localizedDescription)")
                // Parakeet may decode remote audio successfully but return an empty
                // hypothesis for a quiet microphone track. Try the already-installed
                // Apple Speech model on the mic only; never change the remote model.
                if AppSettings.transcriptionModel != .apple {
                    do {
                        onProgress("Retrying microphone with Apple Speech…")
                        micOut = try await Transcriber.transcribeFile(
                            at: micURL, selected: .apple, locale: meetingLocale)
                        NutolaConsoleLog.pipeline(
                            "mic recovered via Apple Speech (\(micOut?.segments.count ?? 0) segments)")
                    } catch {
                        NutolaConsoleLog.pipeline(
                            "mic Apple fallback unavailable — \(error.localizedDescription)")
                    }
                }
                if micOut == nil {
                    notices.append(MeetingNotice.micTranscriptionFailed)
                }
            }
        }
        if hasSystem {
            onProgress("Transcribing the call audio…")
            do { systemOut = try await Transcriber.transcribeFile(at: systemURL, selected: AppSettings.transcriptionModel, locale: meetingLocale) }
            catch {
                notices.append(MeetingNotice.callTranscriptionFailed)
                NutolaConsoleLog.pipeline("system transcription failed — \(error.localizedDescription)")
            }
        }

        guard micOut != nil || systemOut != nil else {
            // No accurate transcript from this session. If a draft (and any live
            // transcript AppState already surfaced) exist, keep them rather than
            // failing the meeting — and still name the meeting from the draft.
            if let draft, meeting.calendarEventTitle == nil {
                onProgress("Naming the meeting…")
                outcome.generatedTitle = await generateTitle(summary: draft.text, provider: draft.provider)
            }
            onSummary(.done)
            outcome.state = (draft == nil && priorSegments.isEmpty) ? .failed : .ready
            outcome.summaryProvider = draft?.provider
            let hasTranscriptContent = !priorSegments.isEmpty || !liveSegments.isEmpty || draft != nil
            outcome.notice = notices.isEmpty
                ? ((draft == nil && priorSegments.isEmpty) ? MeetingNotice.noAudioTranscribed : nil)
                : MeetingNotice.finalizedNotice(notices, hasTranscriptContent: hasTranscriptContent)
            NutolaConsoleLog.pipeline("run finished state=\(outcome.state) (no audio transcribed)")
            return outcome
        }

        // 2. Speakers — hybrid: Zoom AX timeline + on-device diarization for gaps.
        var turns: [DiarizedTurn]?
        var namedSpeakers = false
        let participants = archive.platformParticipants(for: id)
        let explicitIdentity = participants != nil
        let platformEvents = archive.platformSpeakerEvents(for: id)
            .filter { explicitIdentity || !ZoomActiveSpeakerReader.isLocalParticipant($0.name) }
        let roster = participants?.map(\.name) ?? archive.zoomRoster(for: id)
        NutolaConsoleLog.pipeline(
            "speakers meeting=\(id.uuidString.prefix(8)) platformEvents=\(platformEvents.count)"
                + " roster=\(roster.count) identifySpeakers=\(AppSettings.identifySpeakers)")

        var diarizedTurns: [DiarizedTurn]?
        if AppSettings.identifySpeakers, hasSystem {
            onProgress(platformEvents.isEmpty ? "Identifying speakers…" : "Identifying speakers (hybrid)…")
            do {
                // A browser panel can expose only a visible subset; it is not an upper bound.
                let maxSpeakers = explicitIdentity ? nil : (meeting.attendees.isEmpty
                    ? (roster.isEmpty ? nil : roster.count)
                    : meeting.attendees.count)
                diarizedTurns = try await Diarizer.diarize(fileURL: systemURL, maxSpeakers: maxSpeakers)
            } catch {
                notices.append(MeetingNotice.speakerIdentificationUnavailable)
                NutolaConsoleLog.pipeline("diarization failed — \(error.localizedDescription)")
            }
        }

        if !platformEvents.isEmpty {
            if let diarizedTurns, !diarizedTurns.isEmpty {
                let merged = SpeakerTurnMerger.merge(
                    platformEvents: platformEvents,
                    diarized: diarizedTurns,
                    roster: explicitIdentity ? [] : roster,
                    attendees: explicitIdentity ? [] : meeting.attendees)
                turns = merged.turns
                namedSpeakers = merged.hasNamedSpeakers
                outcome.platformSpeakerAttribution = true
                NutolaConsoleLog.pipeline(
                    "hybrid timeline: \(merged.turns.map { formatTurnRange(speaker: $0.speaker, start: $0.start, end: $0.end) }.joined(separator: ", "))")
            } else {
                onProgress("Labeling speakers from the meeting…")
                turns = PlatformSpeakerTurnBuilder.turns(
                    from: PlatformSpeakerTurnBuilder.normalized(platformEvents))
                namedSpeakers = true
                outcome.platformSpeakerAttribution = true
                NutolaConsoleLog.pipeline(
                    "using meeting timeline only: \(turns?.map { formatTurnRange(speaker: $0.speaker, start: $0.start, end: $0.end) }.joined(separator: ", ") ?? "")")
            }
        } else if let diarizedTurns {
            turns = diarizedTurns
            NutolaConsoleLog.pipeline("using diarization only (\(diarizedTurns.count) turns)")
        }

        // Inspect the recorded audio before attributing microphone duplicates
        // to the local speaker. Errors leave the original transcript intact.
        let echoEvidence: AcousticEchoEvidence?
        if micOut != nil && systemOut != nil {
            do {
                echoEvidence = try AcousticEchoEvidence.load(
                    microphoneURL: micURL, systemURL: systemURL)
            } catch {
                echoEvidence = nil
                NutolaConsoleLog.pipeline(
                    "acoustic echo check unavailable — \(error.localizedDescription)")
            }
        } else {
            echoEvidence = nil
        }

        let myName = participants?.first(where: \.isLocal)?.name
            ?? (NSFullUserName().isEmpty ? "Me" : NSFullUserName())
        let (segments, speakers) = SpeakerLabeler.label(
            mic: micOut,
            system: systemOut,
            systemTurns: turns,
            myName: myName,
            namedSpeakers: namedSpeakers,
            echoEvidence: echoEvidence)
        let offsetSegments = Self.offsetSegments(segments, by: appendOffset)
        let mergedSegments = priorSegments + offsetSegments
        do { try archive.saveTranscript(mergedSegments, for: id) }
        catch {
            outcome.state = .failed
            outcome.notice = "The transcript could not be saved. Keep Nutola open and retry saving."
            onSummary(.done)
            return outcome
        }
        // The meeting may still hold provisional live speakers ("me"/"them").
        // Once the final transcript replaces live.json, never keep speaker
        // identities that are absent from the saved transcript.
        let allSpeakers = Self.mergingSpeakers(existing: meeting.speakers, new: speakers)
        outcome.speakers = Self.speakersPresent(in: mergedSegments, from: allSpeakers)
        var labeled = meeting
        labeled.speakers = outcome.speakers ?? meeting.speakers

        // 3. Improve the notes off the accurate transcript (or write them for the
        //    first time if there was no draft).
        onProgress("Summarizing…")
        let accurateText = TranscriptFormatter.plainText(mergedSegments, speakers: labeled.speakers)
        // Optional transcript cleanup applies ONLY to the text we send the
        // summarizer — the saved transcript stays verbatim so the user's record
        // is faithful. Filler removal + personal dictionary substitutions.
        var summaryText = accurateText
        if AppSettings.fillerRemoval {
            summaryText = FillerWordRemover.clean(summaryText)
        }
        let dictionary = PersonalDictionaryStore()
        if dictionary.hasAny {
            summaryText = dictionary.apply(to: summaryText)
        }
        let finalOutcome: SummaryOutcome
        if let draft, priorSegments.isEmpty, sameContent(liveSegments, segments) {
            // The accurate transcript carries the same words as the live one, so the
            // draft already reflects them — skip a second model call.
            finalOutcome = .success(draft.text, provider: draft.provider)
        } else if draft != nil {
            // Improve quietly: the draft stays on screen (badge: "Draft · improving")
            // and is replaced atomically when the better version lands.
            finalOutcome = await summarize(
                meeting: labeled, transcript: summaryText, userNotes: userNotes)
        } else {
            // No draft — stream the sole pass into the notes.
            onSummary(.streaming(""))
            finalOutcome = await summarize(
                meeting: labeled, transcript: summaryText, userNotes: userNotes,
                onDelta: { onSummary(.streaming($0)) })
        }

        // Track the summary text we persisted so the naming stage can reuse it
        // instead of re-reading `archive.summary(for:)` from disk. Stays nil in
        // the edit-guard-blocked and failure paths, where we still must read the
        // (possibly user-edited) file to name the meeting accurately.
        var savedSummary: String?
        switch finalOutcome {
        case .success(let summary, let provider):
            // Edit-guard: if the user edited the draft while we were transcribing,
            // keep their version rather than clobbering it with the improvement.
            if archive.summary(for: id) == expectedSummary {
                // Annotate the notes with Zoom participants who joined but weren't
                // on the calendar invite — the call host can see who actually
                // showed up even when the invite didn't list them. Only when the
                // roster has names and extras exist; otherwise no-op.
                let annotated = AdditionalParticipantsAnnotator.annotation(
                    roster: roster,
                    attendees: meeting.attendees)
                    .map { summary + "\n\n" + $0 }
                    ?? summary
                do {
                    try archive.saveSummary(annotated, for: id, replacing: expectedSummary)
                    savedSummary = annotated
                    outcome.summaryProvider = provider
                } catch MeetingArchive.ArchiveError.summaryChanged {
                    // A user edit won the race; keep it.
                } catch {
                    outcome.state = .failed
                    notices.append("The summary could not be saved. Keep Nutola open and retry saving.")
                }
            }
        case .failure(let why):
            // Improvement failed but the draft (if any) stands.
            if draft == nil { notices.append(why) }
        }

        // Name the meeting from whatever notes we ended up with — the improvement,
        // the draft it fell back to, or the user's own edit — so a draft-only or
        // improve-failed meeting still gets a title, not just the happy path.
        // Reuse the just-saved summary when we have it; only re-read from disk
        // when the edit-guard blocked the save (user edited) or the pass failed.
        let finalText = savedSummary ?? archive.summary(for: id)
        if meeting.calendarEventTitle == nil, !finalText.isEmpty {
            onProgress("Naming the meeting…")
            outcome.generatedTitle = await generateTitle(
                summary: finalText, provider: outcome.summaryProvider ?? "apple")
        }

        onSummary(.done)
        let hasTranscriptContent = !mergedSegments.isEmpty
        outcome.notice = MeetingNotice.finalizedNotice(notices, hasTranscriptContent: hasTranscriptContent)
        NutolaConsoleLog.pipeline(
            "run finished meeting=\(id.uuidString.prefix(8)) state=\(outcome.state)"
                + " segments=\(mergedSegments.count) speakers=\(outcome.speakers?.count ?? 0)"
                + (outcome.generatedTitle.map { " title=\"\($0)\"" } ?? ""))
        return outcome
    }

    enum SummaryOutcome {
        case success(String, provider: String)
        case failure(String)
    }

    /// True when two transcripts carry the same words (ignoring speaker labels and
    /// timing) — used to skip a redundant improvement pass.
    static func sameContent(_ a: [TranscriptSegment], _ b: [TranscriptSegment]) -> Bool {
        func signature(_ segs: [TranscriptSegment]) -> [String] {
            TranscriptText.wordTokens(segs.map(\.text).joined(separator: " "))
        }
        return signature(a) == signature(b)
    }

    /// Detect the exact live segment suffix promoted by ProcessMeetingUseCase.
    /// Never fuzzy-match text: two genuinely repeated utterances must not be
    /// discarded just because their words look similar.
    static func priorSegmentsExcludingPromotedLive(
        _ stored: [TranscriptSegment], live: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !live.isEmpty, stored.count >= live.count else { return stored }
        let suffix = Array(stored.suffix(live.count))
        guard let firstStored = suffix.first, let firstLive = live.first else {
            return stored
        }
        let shift = firstStored.start - firstLive.start
        guard shift >= 0 else { return stored }
        let matches = zip(suffix, live).allSatisfy { pair in
            let saved = pair.0
            let provisional = pair.1
            return saved.speakerID == provisional.speakerID
                && saved.text == provisional.text
                && abs(saved.start - provisional.start - shift) < 0.001
                && abs(saved.end - provisional.end - shift) < 0.001
        }
        return matches ? Array(stored.dropLast(live.count)) : stored
    }

    /// AAC containers can exist on disk with no decoded audio frames (~557 B).
    /// Test the decoded frame count rather than the file's byte size. Parakeet
    /// requires at least 300 ms of audio at 16 kHz.
    static func hasUsableAudio(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return false }
        return Double(file.length) / sampleRate >= 0.3
    }

    static func appendOffset(meeting: Meeting, prior: [TranscriptSegment]) -> TimeInterval {
        guard !prior.isEmpty else { return 0 }
        return max(meeting.duration, prior.map(\.end).max() ?? 0)
    }

    static func offsetSegments(
        _ segments: [TranscriptSegment], by offset: TimeInterval
    ) -> [TranscriptSegment] {
        segments.map { seg in
            var s = seg
            s.start += offset
            s.end += offset
            return s
        }
    }

    static func speakersPresent(
        in segments: [TranscriptSegment], from speakers: [Speaker]
    ) -> [Speaker] {
        let present = Set(segments.map(\.speakerID))
        return speakers.filter { present.contains($0.id) }
    }

    static func mergingSpeakers(existing: [Speaker], new: [Speaker]) -> [Speaker] {
        var merged = existing
        for speaker in new where !merged.contains(where: { $0.id == speaker.id }) {
            merged.append(speaker)
        }
        return merged
    }

    /// Routes to the user's chosen assistant first. Apple Intelligence is the default
    /// on-device path; Claude/Codex run first when selected. When `onDelta` is given,
    /// the chosen engine streams its markdown as it's generated.
    static func summarize(
        meeting: Meeting,
        transcript: String,
        userNotes: String = "",
        forceProvider: AIProvider? = nil,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async -> SummaryOutcome {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("The transcript was empty, so there is nothing to summarize.")
        }
        let templates = TemplateStore()
        let template = templates.template(named: meeting.templateName ?? AppSettings.defaultTemplate)
            ?? TemplateStore.builtins[0]
        let filled = TemplateRenderer.fill(template.body, meeting: meeting)
        var prompt = """
        Write meeting notes from the transcript provided as input, following this \
        template exactly (keep its headings; omit sections that would be empty):

        \(filled)
        """
        let trimmedNotes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            prompt += """


            The meeting organizer took these notes during the call — treat them as \
            authoritative context and weave them into the summary where relevant:

            \(trimmedNotes)
            """
        }
        let systemPrompt = "You are Nutola, a meeting notetaker. Output only clean Markdown notes — no preamble, no code fences."

        // Each engine returns a summary, or nil if it's unavailable or errors (so we
        // fall through to the other). Claude records its error so a Claude-only
        // failure still surfaces a useful message.
        func apple() async -> SummaryOutcome? {
            guard AppleSummarizer.isAvailable else { return nil }
            let summary: String?
            if let onDelta {
                summary = try? await AppleSummarizer.summarizeStreaming(
                    transcript: transcript, filledTemplate: filled, onDelta: onDelta)
            } else {
                summary = try? await AppleSummarizer.summarize(
                    transcript: transcript, filledTemplate: filled)
            }
            if let summary {
                TokenUsageTracker.shared.record(
                    promptTokens: estimateTokens(transcript + filled),
                    completionTokens: estimateTokens(summary))
                return .success(summary, provider: "apple")
            }
            return nil
        }
        var claudeError: String?
        var codexError: String?
        var agentError: String?
        func claude() async -> SummaryOutcome? {
            guard ClaudeCLI.isInstalled else { return nil }
            do {
                let result: ClaudeCLI.RunResult
                if let onDelta {
                    // Fall back to the buffered run if the streaming path itself fails
                    // (e.g. a stream-json parse issue) — same CLI, same result shape.
                    do {
                        result = try await ClaudeCLI.stream(
                            prompt: prompt, stdin: transcript, systemPrompt: systemPrompt, onDelta: onDelta)
                    } catch {
                        result = try await ClaudeCLI.run(
                            prompt: prompt, stdin: transcript, systemPrompt: systemPrompt)
                    }
                } else {
                    result = try await ClaudeCLI.run(
                        prompt: prompt, stdin: transcript, systemPrompt: systemPrompt)
                }
                TokenUsageTracker.shared.record(
                    promptTokens: estimateTokens(prompt + transcript),
                    completionTokens: estimateTokens(result.text))
                return .success(result.text, provider: "claude")
            } catch {
                claudeError = error.localizedDescription
                NutolaConsoleLog.intelligence("claude: \(error.localizedDescription)")
                return nil
            }
        }
        func codex() async -> SummaryOutcome? {
            guard CodexCLI.isReady else { return nil }
            do {
                let result = try await CodexCLI.run(
                    prompt: prompt, stdin: transcript, systemPrompt: systemPrompt)
                if let onDelta { onDelta(result.text) }
                TokenUsageTracker.shared.record(
                    promptTokens: estimateTokens(prompt + transcript),
                    completionTokens: estimateTokens(result.text))
                return .success(result.text, provider: "codex")
            } catch {
                codexError = error.localizedDescription
                NutolaConsoleLog.intelligence("codex: \(error.localizedDescription)")
                return nil
            }
        }

        func agent(_ provider: AIProvider) async -> SummaryOutcome? {
            guard AgentCLI.isInstalled(provider) else { return nil }
            do {
                let text = try await AgentCLI.run(provider: provider, prompt: prompt, stdin: transcript, systemPrompt: systemPrompt)
                if let onDelta { onDelta(text) }
                TokenUsageTracker.shared.record(
                    promptTokens: estimateTokens(prompt + transcript), completionTokens: estimateTokens(text))
                return .success(text, provider: provider.rawValue)
            } catch {
                agentError = error.localizedDescription
                NutolaConsoleLog.intelligence("\(provider.displayName): \(error.localizedDescription)")
                return nil
            }
        }

        if let forceProvider {
            let name = forceProvider.displayName
            let engine: () async -> SummaryOutcome?
            switch forceProvider {
            case .apple: engine = apple
            case .claude: engine = claude
            case .codex: engine = codex
            case .opencode, .vibe: engine = { await agent(forceProvider) }
            }
            NutolaConsoleLog.intelligence("summarize: forced \(name)")
            if let outcome = await engine() {
                if case .success(_, let provider) = outcome {
                    NutolaConsoleLog.intelligence("summarize: succeeded via \(provider)")
                }
                return outcome
            }
            switch forceProvider {
            case .apple:
                let reason = AppleSummarizer.unavailableReason ?? "Apple Intelligence is unavailable"
                return .failure("\(reason) — couldn't regenerate with Apple Intelligence.")
            case .claude:
                if let claudeError {
                    return .failure("Summary failed via Claude: \(claudeError)")
                }
                return .failure("Claude isn't ready — install the CLI and sign in, then try again.")
            case .codex:
                if let codexError {
                    return .failure("Summary failed via Codex: \(codexError)")
                }
                return .failure("Codex isn't ready — install the CLI and sign in, then try again.")
            case .opencode, .vibe:
                return .failure(agentError.map { "Summary failed via \(name): \($0)" }
                    ?? "\(name) isn't ready — install and configure its CLI, then try again.")
            }
        }

        let preferred = AppSettings.preferredAIProvider
        let cloudPrimary: () async -> SummaryOutcome?
        if preferred == .opencode || preferred == .vibe {
            cloudPrimary = { await agent(preferred) }
        } else {
            cloudPrimary = preferred == .codex ? codex : claude
        }
        let cloudFallback: () async -> SummaryOutcome? = preferred == .codex ? claude : codex
        let cloudReady = preferred.isCloud && preferred.isAvailableForSummary

        let order: [() async -> SummaryOutcome?]
        let orderNames: [String]
        switch preferred {
        case .apple:
            order = [apple, claude, codex]
            orderNames = ["Apple Intelligence", "Claude", "Codex"]
        case .claude, .codex, .opencode, .vibe:
            let primary = preferred.displayName
            let fallback = preferred == .codex ? "Claude" : "Codex"
            if cloudReady {
                if AppSettings.preferClaudeSummaries {
                    order = [cloudPrimary, cloudFallback]
                    orderNames = [primary, fallback]
                } else {
                    order = [cloudPrimary, apple, cloudFallback]
                    orderNames = [primary, "Apple Intelligence", fallback]
                }
            } else {
                order = [apple, cloudPrimary, cloudFallback]
                orderNames = ["Apple Intelligence", primary, fallback]
            }
        }
        let modeLabel = preferred.isCloud && cloudReady
            ? (AppSettings.preferClaudeSummaries ? " · cloud-only" : " · cloud-first")
            : ""
        NutolaConsoleLog.intelligence(
            "summarize: \(transcript.count) chars · preferred \(preferred.displayName)\(modeLabel)"
                + " · order: \(orderNames.joined(separator: " → "))")

        for (name, engine) in zip(orderNames, order) {
            NutolaConsoleLog.intelligence("summarize: trying \(name)…")
            if let outcome = await engine() {
                if case .success(_, let provider) = outcome {
                    NutolaConsoleLog.intelligence("summarize: succeeded via \(provider)")
                }
                return outcome
            }
            NutolaConsoleLog.intelligence("summarize: \(name) unavailable or failed")
        }

        if preferred == .apple {
            let reason = AppleSummarizer.unavailableReason ?? "Apple Intelligence is unavailable"
            NutolaConsoleLog.intelligence("summarize: failed — \(reason)")
            return .failure("\(reason) — transcript saved, summary skipped. Enable Apple Intelligence and press Regenerate.")
        }
        if preferred == .codex, let codexError {
            NutolaConsoleLog.intelligence("summarize: failed via Codex — \(codexError)")
            return .failure("Summary failed via Codex: \(codexError)")
        }
        if let agentError, preferred == .opencode || preferred == .vibe {
            return .failure("Summary failed via \(preferred.displayName): \(agentError)")
        }
        if let claudeError {
            NutolaConsoleLog.intelligence("summarize: failed via Claude — \(claudeError)")
            return .failure("Summary failed via Claude: \(claudeError)")
        }
        let cloudName = preferred.displayName
        let reason = AppleSummarizer.unavailableReason ?? "Apple Intelligence is unavailable"
        NutolaConsoleLog.intelligence("summarize: failed — \(reason); \(cloudName) not ready")
        return .failure("\(reason), and \(cloudName) isn't ready — transcript saved, summary skipped. Fix either one and press Regenerate.")
    }

    /// Cap on summary chars fed to the title-generation prompt — long notes would
    /// blow the context window without helping the title, and the CLIs charge
    /// by the token. Was a bare `2000` at both call sites; centralized here.
    private static let maxTitleSourceChars = 2000

    static func generateTitle(summary: String, provider: String) async -> String? {
        NutolaConsoleLog.intelligence("title: generating via \(provider)")
        if provider == "apple", let title = try? await AppleSummarizer.generateTitle(fromSummary: summary) {
            NutolaConsoleLog.intelligence("title: Apple Intelligence → \"\(title)\"")
            TokenUsageTracker.shared.record(
                promptTokens: estimateTokens(summary), completionTokens: estimateTokens(title))
            return cleaned(title)
        }
        if let selected = AIProvider(rawValue: provider), selected == .opencode || selected == .vibe,
           let text = try? await AgentCLI.run(
               provider: selected,
               prompt: "Reply with only a specific 3–8 word title for the meeting with these notes, no quotes:\n\n\(String(summary.prefix(maxTitleSourceChars)))") {
            TokenUsageTracker.shared.record(
                promptTokens: estimateTokens(summary), completionTokens: estimateTokens(text))
            return cleaned(text)
        }
        if provider == "codex", CodexCLI.isInstalled,
           let result = try? await CodexCLI.run(
               prompt: "Reply with only a specific 3–8 word title for the meeting with these notes, no quotes:\n\n\(String(summary.prefix(maxTitleSourceChars)))"
           ) {
            NutolaConsoleLog.intelligence("title: Codex → \"\(result.text)\"")
            TokenUsageTracker.shared.record(
                promptTokens: estimateTokens(summary), completionTokens: estimateTokens(result.text))
            return cleaned(result.text)
        }
        if ClaudeCLI.isInstalled,
           let result = try? await ClaudeCLI.run(
               prompt: "Reply with only a specific 3–8 word title for the meeting with these notes, no quotes:\n\n\(String(summary.prefix(maxTitleSourceChars)))",
               model: "haiku"
           ) {
            NutolaConsoleLog.intelligence("title: Claude → \"\(result.text)\"")
            TokenUsageTracker.shared.record(
                promptTokens: estimateTokens(summary), completionTokens: estimateTokens(result.text))
            return cleaned(result.text)
        }
        NutolaConsoleLog.intelligence("title: no engine produced a title")
        return nil
    }

    /// Rough token estimate shared by the summary/title engines (~4 chars/token,
    /// the TN3193 heuristic). CLIs don't expose real token counts, so we
    /// approximate to keep the usage chart populated.
    private static func estimateTokens(_ text: String) -> Int {
        max(text.count / 4, 1)
    }

    private static func cleaned(_ title: String) -> String? {
        let t = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.#"))
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 80, !t.contains("\n") else { return nil }
        return t
    }
}
