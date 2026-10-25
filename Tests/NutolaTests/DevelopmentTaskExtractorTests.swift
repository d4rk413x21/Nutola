import XCTest
@testable import Nutola

final class DevelopmentTaskExtractorTests: XCTestCase {
    private var meeting: Meeting {
        var meeting = Meeting(title: "Planning", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.state = .ready
        meeting.speakers = [Speaker(id: "s1", name: "Alice")]
        return meeting
    }

    private var transcript: [TranscriptSegment] {
        [
            TranscriptSegment(speakerID: "s1", start: 12, end: 20,
                              text: "The login fails after a token expires. I'll fix the refresh."),
            TranscriptSegment(speakerID: "s1", start: 40, end: 48,
                              text: "Keep the existing session and add a regression test."),
        ]
    }

    private func response(owner: String? = nil, evidence: [Int] = [1]) throws -> String {
        let candidate = DevelopmentTaskExtractor.Candidate(
            title: "Fix token refresh", detail: "Preserve the session after token expiry.",
            owner: owner, evidence: evidence)
        let data = try JSONEncoder().encode(["tasks": [candidate]])
        return String(decoding: data, as: UTF8.self)
    }

    func testDecodeNormalizesDraftsAndRetainsUnassignedOwner() throws {
        let result = try DevelopmentTaskExtractor.decode(
            response(evidence: [2, 1, 2]), transcript: transcript, allowedEvidence: [1, 2], meeting: meeting)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].owner)
        XCTAssertEqual(result[0].evidence, [1, 2])
    }

    func testAcceptsKnownSpeakerAsExplicitOwner() throws {
        let result = try DevelopmentTaskExtractor.decode(
            response(owner: "Alice"), transcript: transcript, allowedEvidence: [1], meeting: meeting)
        XCTAssertEqual(result[0].owner, "Alice")
    }

    func testAcceptsOwnerNamedInCitedPassageEvenWhenNotAnAttendee() throws {
        var segments = transcript
        segments[0].text = "Please ask Marco to implement the refresh."
        let result = try DevelopmentTaskExtractor.decode(
            response(owner: "Marco"), transcript: segments, allowedEvidence: [1], meeting: meeting)
        XCTAssertEqual(result[0].owner, "Marco")
    }

    func testRejectsUnsupportedOwner() throws {
        XCTAssertThrowsError(try DevelopmentTaskExtractor.decode(
            response(owner: "Invented person"), transcript: transcript, allowedEvidence: [1], meeting: meeting))
    }

    func testRejectsMissingOutOfRangeAndNotYetReadEvidence() throws {
        for evidence in [[], [0], [-1], [3], [2]] as [[Int]] {
            XCTAssertThrowsError(try DevelopmentTaskExtractor.decode(
                response(evidence: evidence), transcript: transcript, allowedEvidence: [1], meeting: meeting))
        }
    }

    func testRejectsProseMalformedJSONAndEmptyFields() {
        for text in [
            "Here is your task: fix login",
            "{\"tasks\": [",
            #"{"tasks":[{"title":" ","detail":"Fix login","evidence":[1]}]}"#,
            #"{"tasks":[{"title":"Fix login","detail":" ","evidence":[1]}]}"#,
        ] {
            XCTAssertThrowsError(try DevelopmentTaskExtractor.decode(
                text, transcript: transcript, allowedEvidence: [1], meeting: meeting))
        }
    }

    func testAcceptsJSONCodeFenceAndNoTasks() throws {
        let result = try DevelopmentTaskExtractor.decode(
            "```json\n{\"tasks\":[]}\n```", transcript: transcript, allowedEvidence: [1], meeting: meeting)
        XCTAssertTrue(result.isEmpty)
    }

    func testRejectsDuplicateTitlesIgnoringCaseAndWhitespace() {
        let text = #"{"tasks":[{"title":"Fix login","detail":"One","evidence":[1]},{"title":" FIX   LOGIN ","detail":"Two","evidence":[2]}]}"#
        XCTAssertThrowsError(try DevelopmentTaskExtractor.decode(
            text, transcript: transcript, allowedEvidence: [1, 2], meeting: meeting))
    }

    func testChunkingPreservesOversizedUnicodeUtterancesWithinByteBudget() {
        var segments = transcript
        segments[0].text = String(repeating: "è👩🏽‍💻e\u{301}", count: 3_000)
        segments += (0..<12).map { n in
            TranscriptSegment(speakerID: "s1", start: Double(n + 100), end: Double(n + 101),
                              text: String(repeating: "task \(n) ", count: 1_000))
        }
        let chunks = DevelopmentTaskExtractor.chunks(segments)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.map(\.rendered).joined(separator: "\n\n").utf8.count,
                                     DevelopmentTaskExtractor.batchBytes)
        }
        for (index, segment) in segments.enumerated() {
            let reconstructed = chunks.flatMap { $0 }.filter { $0.index == index + 1 }.map(\.text).joined()
            XCTAssertEqual(Array(reconstructed.utf8), Array(segment.text.utf8))
        }
    }

    func testChunkingSkipsEmptyUtterancesWithoutRenumberingEvidence() {
        var segments = transcript
        segments[0].text = " \n "
        XCTAssertEqual(DevelopmentTaskExtractor.chunks(segments).map { $0.map(\.index) }, [[2]])
    }

    @MainActor
    func testExtractionUsesOriginalPassagesAndCompleteTranscript() async throws {
        let segments = transcript
        let output = try response(evidence: [1, 2])
        let result = try await DevelopmentTaskExtractor.extract(
            meeting: meeting, transcript: segments, analyze: { prompt, input in
                XCTAssertTrue(prompt.contains("untrusted data"))
                for segment in segments { XCTAssertTrue(input.contains(segment.text)) }
                XCTAssertTrue(input.contains("[1] Alice @ 0:12"))
                return output
            })
        XCTAssertEqual(result.tasks[0].evidence, segments)
        XCTAssertEqual(result.transcriptFingerprint, try DevelopmentTaskReview.fingerprint(segments))
        XCTAssertNil(result.tasks[0].owner)
    }

    private var twoParts: [TranscriptSegment] {
        var segments = transcript
        segments[0].text = String(repeating: "We need token refresh. ", count: 250)
        segments[1].text = String(repeating: "Actually, cancel the refresh work: it is already implemented. ", count: 80)
        return segments
    }

    @MainActor
    func testLaterCancellationReconcilesEarlierTaskEvenWithoutNewProposals() async throws {
        let segments = twoParts
        var calls = 0
        var progress: [Int] = []
        let first = try response()
        let result = try await DevelopmentTaskExtractor.extract(
            meeting: meeting, transcript: segments, analyze: { instructions, input in
                calls += 1
                if calls == 1 { return first }
                if instructions == DevelopmentTaskExtractor.prompt {
                    XCTAssertFalse(input.contains("Fix token refresh"))
                    return #"{"tasks":[]}"#
                }
                XCTAssertTrue(input.contains("Fix token refresh"))
                XCTAssertTrue(input.contains(segments[1].text))
                return #"{"updates":[{"id":0,"task":null,"merged":[],"evidence":[2]}]}"#
            }, onProgress: { part, total in
                progress.append(part)
                XCTAssertEqual(total, 2)
            })
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(progress, [1, 2])
        XCTAssertTrue(result.tasks.isEmpty)
    }

    @MainActor
    func testMergeRetainsOriginalSourcesAndAppliesLaterRequirements() async throws {
        var calls = 0
        let first = try response()
        let next = try response(evidence: [2])
        let result = try await DevelopmentTaskExtractor.extract(
            meeting: meeting, transcript: twoParts, analyze: { instructions, _ in
                calls += 1
                if instructions == DevelopmentTaskExtractor.prompt { return calls == 1 ? first : next }
                // The model omits the original source; the reducer must retain it.
                return #"{"updates":[{"id":0,"task":{"title":"Fix token refresh","detail":"Preserve the session and test concurrent refreshes.","evidence":[2]},"merged":[0],"evidence":[2]}]}"#
            })
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertTrue(result.tasks[0].detail.contains("concurrent refreshes"))
        XCTAssertEqual(result.tasks[0].evidence, twoParts)
    }

    @MainActor
    func testLongHistoryIsPagedAndLateCancellationReachesEveryPage() async throws {
        let segments = (0..<18).map { n in
            TranscriptSegment(speakerID: "s1", start: Double(n * 60), end: Double(n * 60 + 30),
                              text: "PART-\(n) " + String(repeating: "meeting discussion ", count: 300))
        }
        var extractionCalls = 0
        var reconciliationCalls = 0
        var lastPartPages = 0
        let result = try await DevelopmentTaskExtractor.extract(
            meeting: meeting, transcript: segments, analyze: { instructions, input in
                XCTAssertLessThanOrEqual(instructions.utf8.count + input.utf8.count,
                                         DevelopmentTaskExtractor.maxRequestBytes)
                if instructions == DevelopmentTaskExtractor.prompt {
                    let n = extractionCalls
                    extractionCalls += 1
                    if n == 17 { return #"{"tasks":[]}"# }
                    let tasks = (0..<3).map { offset in
                        DevelopmentTaskExtractor.Candidate(title: "Task \(n)-\(offset)",
                            detail: String(repeating: "Explicit requirement. ", count: 60), evidence: [n + 1])
                    }
                    return String(decoding: try JSONEncoder().encode(["tasks": tasks]), as: UTF8.self)
                }
                reconciliationCalls += 1
                if input.contains("PART-17 ") {
                    lastPartPages += 1
                    let json = try XCTUnwrap(input.components(separatedBy: "Earlier tasks:\n").last?
                        .components(separatedBy: "\n\nNew proposals:").first)
                    let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
                    if let target = entries.first(where: { ($0["task"] as? [String: Any])?["title"] as? String == "Task 0-0" }),
                       let id = target["id"] as? Int {
                        return "{\"updates\":[{\"id\":\(id),\"task\":null,\"merged\":[],\"evidence\":[18]}]}"
                    }
                }
                return #"{"updates":[]}"#
            })
        XCTAssertEqual(extractionCalls, segments.count)
        XCTAssertGreaterThan(reconciliationCalls, segments.count)
        XCTAssertGreaterThan(lastPartPages, 1)
        XCTAssertEqual(result.tasks.count, 50)
        XCTAssertFalse(result.tasks.contains { $0.title == "Task 0-0" })
        XCTAssertTrue(result.tasks.contains { $0.title == "Task 16-2" })
        XCTAssertGreaterThan(try JSONEncoder().encode(result).count, DevelopmentTaskExtractor.maxRequestBytes)
    }

    @MainActor
    func testReconciliationRejectsUnknownIDsAndUnseenEvidence() async throws {
        for reply in [
            #"{"updates":[{"id":99,"task":null,"merged":[],"evidence":[2]}]}"#,
            #"{"updates":[{"id":0,"task":null,"merged":[],"evidence":[1]}]}"#,
            #"{"updates":[{"id":0,"task":null,"merged":[99],"evidence":[2]}]}"#,
            #"{"updates":[{"id":0,"task":{"title":"Bad","detail":"Invented source","evidence":[99]},"merged":[],"evidence":[2]}]}"#,
            #"{"updates":[{"id":0,"task":null,"merged":[],"evidence":[2]},{"id":0,"task":null,"merged":[],"evidence":[2]}]}"#,
        ] {
            var calls = 0
            let first = try response()
            do {
                _ = try await DevelopmentTaskExtractor.extract(meeting: meeting, transcript: twoParts, analyze: { instructions, _ in
                    calls += 1
                    if calls == 1 { return first }
                    return instructions == DevelopmentTaskExtractor.prompt ? #"{"tasks":[]}"# : reply
                })
                XCTFail("Expected invalid reconciliation")
            } catch DevelopmentTaskError.invalidEvidence {
            } catch DevelopmentTaskError.invalidResponse {
            }
        }
    }

    @MainActor
    func testRejectsOversizedResponseBeforeDecoding() async throws {
        do {
            _ = try await DevelopmentTaskExtractor.extract(meeting: meeting, transcript: transcript, analyze: { _, _ in
                String(repeating: "x", count: DevelopmentTaskExtractor.maxRequestBytes + 1)
            })
            XCTFail("Expected contextTooLarge")
        } catch DevelopmentTaskError.contextTooLarge {}
    }

    @MainActor
    func testRejectsAnIndividualDraftTooLargeToReconcile() async throws {
        let candidate = DevelopmentTaskExtractor.Candidate(title: "Too large",
            detail: String(repeating: "x", count: DevelopmentTaskExtractor.batchBytes + 1), evidence: [1])
        let output = String(decoding: try JSONEncoder().encode(["tasks": [candidate]]), as: UTF8.self)
        do {
            _ = try await DevelopmentTaskExtractor.extract(meeting: meeting, transcript: transcript, analyze: { _, _ in output })
            XCTFail("Expected contextTooLarge")
        } catch DevelopmentTaskError.contextTooLarge {}
    }

    @MainActor
    func testSplitUtteranceKeepsOriginalEvidence() async throws {
        var segments = transcript
        segments = [segments[0]]
        segments[0].text = String(repeating: "Fix the login. 👩🏽‍💻 ", count: 1_500)
        let first = try response()
        var calls = 0
        let result = try await DevelopmentTaskExtractor.extract(meeting: meeting, transcript: segments, analyze: { instructions, input in
            XCTAssertLessThanOrEqual(instructions.utf8.count + input.utf8.count, DevelopmentTaskExtractor.maxRequestBytes)
            calls += 1
            if calls == 1 { return first }
            return instructions == DevelopmentTaskExtractor.prompt ? #"{"tasks":[]}"# : #"{"updates":[]}"#
        })
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].evidence, segments)
    }

    @MainActor
    func testNoTranscriptDoesNotCallTheCLI() async {
        do {
            _ = try await DevelopmentTaskExtractor.extract(
                meeting: meeting, transcript: [], analyze: { _, _ in
                    XCTFail("No CLI should be invoked")
                    return ""
                })
            XCTFail("Expected noTranscript")
        } catch DevelopmentTaskError.noTranscript {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCancellationPreventsAnalysis() async {
        let meeting = self.meeting
        let transcript = self.transcript
        let task = Task {
            try await DevelopmentTaskExtractor.extract(
                meeting: meeting, transcript: transcript, analyze: { _, _ in
                    XCTFail("Cancelled extraction must not launch the CLI")
                    return ""
                })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFingerprintIsStableAfterReloadAndDetectsEditsWithTheSameIDs() throws {
        let original = transcript
        var edited = try JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(try DevelopmentTaskReview.fingerprint(original), try DevelopmentTaskReview.fingerprint(edited))
        edited[0].text = "Cancel the refresh work."
        XCTAssertNotEqual(try DevelopmentTaskReview.fingerprint(original), try DevelopmentTaskReview.fingerprint(edited))
    }

    func testMarkdownIncludesOnlySelectedDraftsAndOriginalEvidence() {
        let meeting = self.meeting
        let included = DevelopmentTaskDraft(title: "Fix login", detail: "Handle token expiry.", evidence: transcript)
        let excluded = DevelopmentTaskDraft(title: "Excluded task", detail: "Not selected", evidence: [])
        let review = DevelopmentTaskReview(tasks: [included, excluded])
        let markdown = review.markdown(meeting: meeting, selectedIDs: [included.id])
        XCTAssertTrue(markdown.contains("Fix login"))
        XCTAssertTrue(markdown.contains("Owner: Unassigned"))
        XCTAssertTrue(markdown.contains(meeting.id.uuidString))
        XCTAssertTrue(markdown.contains("Alice @ 0:12"))
        XCTAssertTrue(markdown.contains(transcript[0].text))
        XCTAssertFalse(markdown.contains("Excluded task"))
    }
}
