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

    func testChunkingIncludesEveryUtteranceEvenAnOversizedOne() {
        var segments = transcript
        segments[0].text = String(repeating: "è", count: 30_000)
        segments += (0..<12).map { n in
            TranscriptSegment(speakerID: "s1", start: Double(n + 100), end: Double(n + 101),
                              text: String(repeating: "task \(n) ", count: 1_000))
        }
        let chunks = DevelopmentTaskExtractor.chunks(segments)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(segments.indices))
        XCTAssertEqual(chunks.first, [0])
    }

    func testChunkingSkipsEmptyUtterancesWithoutRenumberingEvidence() {
        var segments = transcript
        segments[0].text = " \n "
        XCTAssertEqual(DevelopmentTaskExtractor.chunks(segments), [[1]])
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

    @MainActor
    func testLaterPartsReceiveAndCanReviseEarlierDrafts() async throws {
        var segments = transcript
        segments[0].text = String(repeating: "We need token refresh. ", count: 1_500)
        segments[1].text = "Actually, cancel the refresh work: it is already implemented."
        var calls = 0
        var progress: [Int] = []
        let first = try response()
        let result = try await DevelopmentTaskExtractor.extract(
            meeting: meeting, transcript: segments, analyze: { _, input in
                calls += 1
                if calls == 1 { return first }
                XCTAssertTrue(input.contains("Fix token refresh"))
                XCTAssertTrue(input.contains(segments[1].text))
                return #"{"tasks":[]}"#
            }, onProgress: { part, total in
                progress.append(part)
                XCTAssertEqual(total, 2)
            })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(progress, [1, 2])
        XCTAssertTrue(result.tasks.isEmpty)
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
