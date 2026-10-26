import Foundation
import Testing
@testable import Nutola

struct DevelopmentTaskExtractorTests {
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

    @Test func testDecodeNormalizesDraftsAndRetainsUnassignedOwner() throws {
        let result = try DevelopmentTaskExtractor.decode(
            response(evidence: [2, 1, 2]), transcript: transcript, allowedEvidence: [1, 2], meeting: meeting)
        #expect(result.count == 1)
        #expect(result[0].owner == nil)
        #expect(result[0].evidence == [1, 2])
    }

    @Test func testAcceptsKnownSpeakerAsExplicitOwner() throws {
        let result = try DevelopmentTaskExtractor.decode(
            response(owner: "Alice"), transcript: transcript, allowedEvidence: [1], meeting: meeting)
        #expect(result[0].owner == "Alice")
    }

    @Test func testAcceptsOwnerNamedInCitedPassageEvenWhenNotAnAttendee() throws {
        var segments = transcript
        segments[0].text = "Please ask Marco to implement the refresh."
        let result = try DevelopmentTaskExtractor.decode(
            response(owner: "Marco"), transcript: segments, allowedEvidence: [1], meeting: meeting)
        #expect(result[0].owner == "Marco")
    }

    @Test func testRejectsUnsupportedOwner() throws {
        #expect(throws: (any Error).self) { try DevelopmentTaskExtractor.decode(
            response(owner: "Invented person"), transcript: transcript, allowedEvidence: [1], meeting: meeting) }
    }

    @Test func testRejectsMissingOutOfRangeAndNotYetReadEvidence() throws {
        for evidence in [[], [0], [-1], [3], [2]] as [[Int]] {
            #expect(throws: (any Error).self) { try DevelopmentTaskExtractor.decode(
                response(evidence: evidence), transcript: transcript, allowedEvidence: [1], meeting: meeting) }
        }
    }

    @Test func testRejectsProseMalformedJSONAndEmptyFields() {
        for text in [
            "Here is your task: fix login",
            "{\"tasks\": [",
            #"{"tasks":[{"title":" ","detail":"Fix login","evidence":[1]}]}"#,
            #"{"tasks":[{"title":"Fix login","detail":" ","evidence":[1]}]}"#,
        ] {
            #expect(throws: (any Error).self) { try DevelopmentTaskExtractor.decode(
                text, transcript: transcript, allowedEvidence: [1], meeting: meeting) }
        }
    }

    @Test func testAcceptsJSONCodeFenceAndNoTasks() throws {
        let result = try DevelopmentTaskExtractor.decode(
            "```json\n{\"tasks\":[]}\n```", transcript: transcript, allowedEvidence: [1], meeting: meeting)
        #expect(result.isEmpty)
    }

    @Test func testRejectsDuplicateTitlesIgnoringCaseAndWhitespace() {
        let text = #"{"tasks":[{"title":"Fix login","detail":"One","evidence":[1]},{"title":" FIX   LOGIN ","detail":"Two","evidence":[2]}]}"#
        #expect(throws: (any Error).self) { try DevelopmentTaskExtractor.decode(
            text, transcript: transcript, allowedEvidence: [1, 2], meeting: meeting) }
    }

    @Test func testChunkingIncludesEveryUtteranceEvenAnOversizedOne() {
        var segments = transcript
        segments[0].text = String(repeating: "è", count: 30_000)
        segments += (0..<12).map { n in
            TranscriptSegment(speakerID: "s1", start: Double(n + 100), end: Double(n + 101),
                              text: String(repeating: "task \(n) ", count: 1_000))
        }
        let chunks = DevelopmentTaskExtractor.chunks(segments)
        #expect(chunks.count > 2)
        #expect(chunks.flatMap { $0 } == Array(segments.indices))
        #expect(chunks.first == [0])
    }

    @Test func testChunkingSkipsEmptyUtterancesWithoutRenumberingEvidence() {
        var segments = transcript
        segments[0].text = " \n "
        #expect(DevelopmentTaskExtractor.chunks(segments) == [[1]])
    }

    @MainActor
    @Test func testExtractionUsesOriginalPassagesAndCompleteTranscript() async throws {
        let segments = transcript
        let output = try response(evidence: [1, 2])
        let result = try await DevelopmentTaskExtractor.extract(
            meeting: meeting, transcript: segments, analyze: { prompt, input in
                #expect(prompt.contains("untrusted data"))
                for segment in segments { #expect(input.contains(segment.text)) }
                #expect(input.contains("[1] Alice @ 0:12"))
                return output
            })
        #expect(result.tasks[0].evidence == segments)
        #expect(try result.transcriptFingerprint == DevelopmentTaskReview.fingerprint(segments))
        #expect(result.tasks[0].owner == nil)
    }

    @MainActor
    @Test func testLaterPartsReceiveAndCanReviseEarlierDrafts() async throws {
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
                #expect(input.contains("Fix token refresh"))
                #expect(input.contains(segments[1].text))
                return #"{"tasks":[]}"#
            }, onProgress: { part, total in
                progress.append(part)
                #expect(total == 2)
            })
        #expect(calls == 2)
        #expect(progress == [1, 2])
        #expect(result.tasks.isEmpty)
    }

    @MainActor
    @Test func testNoTranscriptDoesNotCallTheCLI() async {
        do {
            _ = try await DevelopmentTaskExtractor.extract(
                meeting: meeting, transcript: [], analyze: { _, _ in
                    Issue.record("No CLI should be invoked")
                    return ""
                })
            Issue.record("Expected noTranscript")
        } catch DevelopmentTaskError.noTranscript {
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @MainActor
    @Test func testCancellationPreventsAnalysis() async {
        let meeting = self.meeting
        let transcript = self.transcript
        let task = Task {
            try await DevelopmentTaskExtractor.extract(
                meeting: meeting, transcript: transcript, analyze: { _, _ in
                    Issue.record("Cancelled extraction must not launch the CLI")
                    return ""
                })
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func testFingerprintIsStableAfterReloadAndDetectsEditsWithTheSameIDs() throws {
        let original = transcript
        var edited = try JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(original))
        #expect(try DevelopmentTaskReview.fingerprint(original) == DevelopmentTaskReview.fingerprint(edited))
        edited[0].text = "Cancel the refresh work."
        #expect(try DevelopmentTaskReview.fingerprint(original) != DevelopmentTaskReview.fingerprint(edited))
    }

    @Test func testMarkdownIncludesOnlySelectedDraftsAndOriginalEvidence() {
        let meeting = self.meeting
        let included = DevelopmentTaskDraft(title: "Fix login", detail: "Handle token expiry.", evidence: transcript)
        let excluded = DevelopmentTaskDraft(title: "Excluded task", detail: "Not selected", evidence: [])
        let review = DevelopmentTaskReview(tasks: [included, excluded])
        let markdown = review.markdown(meeting: meeting, selectedIDs: [included.id])
        #expect(markdown.contains("Fix login"))
        #expect(markdown.contains("Owner: Unassigned"))
        #expect(markdown.contains(meeting.id.uuidString))
        #expect(markdown.contains("Alice @ 0:12"))
        #expect(markdown.contains(transcript[0].text))
        #expect(!(markdown.contains("Excluded task")))
    }
}
