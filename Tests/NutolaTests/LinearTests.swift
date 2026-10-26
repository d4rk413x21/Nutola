import XCTest
@testable import Nutola

@MainActor
final class LinearTests: XCTestCase {
    private let workspace = "workspace-id"
    private let team = "team-id"
    private let project = "project-id"

    private func reply(_ data: [String: Any], status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: data),
         HTTPURLResponse(url: URL(string: "https://api.linear.app/graphql")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func issue(_ id: UUID, url: String = "https://linear.app/work/issue/DEV-12/task") -> [String: Any] {
        ["id": id.uuidString, "identifier": "DEV-12", "url": url,
         "team": ["id": team], "project": ["id": project]]
    }

    private func lookup(_ issues: [[String: Any]]) -> [String: Any] {
        ["data": ["organization": ["id": workspace, "name": "Work"], "issues": ["nodes": issues]]]
    }

    private func review(count: Int = 1) -> DevelopmentTaskReview {
        DevelopmentTaskReview(transcriptFingerprint: "original", tasks: (0..<count).map { n in
            DevelopmentTaskDraft(title: "Fix login \(n)", detail: "Handle expired tokens.", owner: "Alice",
                evidence: [TranscriptSegment(speakerID: "s1", start: 12, end: 15, text: "Fix the expired token flow.")])
        })
    }

    private var meeting: Meeting {
        var meeting = Meeting(title: "Planning", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.speakers = [Speaker(id: "s1", name: "Alice")]
        return meeting
    }

    func testPersonalKeyIsTrimmedAndSentOnlyInAuthorizationHeader() async throws {
        let client = try LinearClient(apiKey: "  secret-key\n", transport: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.linear.app/graphql")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "secret-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("secret-key"))
            return try self.reply(["data": ["organization": ["id": self.workspace, "name": "Work"],
                "teams": ["nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]])
        })
        let result = try await client.teams()
        XCTAssertEqual(result.workspace.id, workspace)
        XCTAssertTrue(result.teams.isEmpty)
    }

    func testRejectsEmptyOrInjectedKeysWithoutNetworkCalls() {
        for key in ["", " \n ", "key\r\nInjected: value", "two keys"] {
            XCTAssertThrowsError(try LinearClient(apiKey: key))
        }
    }

    func testPaginatesTeamsAndProjectsUsingCursors() async throws {
        var calls = 0
        let client = try LinearClient(apiKey: "key", transport: { request in
            let body = try self.body(request)
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            let query = try XCTUnwrap(body["query"] as? String)
            calls += 1
            let first = calls == 1 || calls == 3
            XCTAssertEqual(variables["after"] as? String, first ? nil : "next")
            let page: [String: Any] = ["nodes": query.contains("NutolaTeams")
                ? [["id": "t\(calls)", "name": "Team \(calls)", "key": "DEV"]]
                : [["id": "p\(calls)", "name": "Project \(calls)"]],
                "pageInfo": ["hasNextPage": first, "endCursor": first ? "next" as Any : NSNull()]]
            if query.contains("NutolaTeams") {
                return try self.reply(["data": ["organization": ["id": self.workspace, "name": "Work"], "teams": page]])
            }
            XCTAssertEqual(variables["team"] as? String, self.team)
            return try self.reply(["data": ["team": ["projects": page]]])
        })
        let teams = try await client.teams()
        let projects = try await client.projects(teamID: team)
        XCTAssertEqual(teams.teams.count, 2)
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(calls, 4)
    }

    func testRejectsRepeatedPaginationCursors() async throws {
        var calls = 0
        let client = try LinearClient(apiKey: "key", transport: { _ in
            calls += 1
            return try self.reply(["data": ["organization": ["id": self.workspace, "name": "Work"],
                "teams": ["nodes": [], "pageInfo": ["hasNextPage": true, "endCursor": "repeat"]]]])
        })
        do { _ = try await client.teams(); XCTFail("Expected invalid response") }
        catch LinearError.invalidResponse {}
        XCTAssertEqual(calls, 2)
    }

    func testHTTPAndGraphQLErrorsDoNotExposeServerSecrets() async throws {
        for status in [401, 403, 429, 500, 200] {
            let client = try LinearClient(apiKey: "private-key", transport: { _ in
                try self.reply(["errors": [["message": "private-key echoed by server"]]], status: status)
            })
            do { _ = try await client.teams(); XCTFail("Expected failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private-key")) }
        }
    }

    func testMutationUsesStableIDAndSelectedDestinationWithoutGuessingAssignee() async throws {
        let id = UUID()
        let client = try LinearClient(apiKey: "key", transport: { request in
            let variables = try XCTUnwrap(self.body(request)["variables"] as? [String: Any])
            let input = try XCTUnwrap(variables["input"] as? [String: Any])
            XCTAssertEqual(input["id"] as? String, id.uuidString)
            XCTAssertEqual(input["title"] as? String, "Fix login")
            XCTAssertEqual(input["description"] as? String, "Details and evidence")
            XCTAssertEqual(input["teamId"] as? String, self.team)
            XCTAssertEqual(input["projectId"] as? String, self.project)
            XCTAssertNil(input["assigneeId"])
            return try self.reply(["data": ["issueCreate": ["success": true, "issue": self.issue(id)]]])
        })
        let result = try await client.createIssue(id: id, title: "Fix login", description: "Details and evidence", teamID: team, projectID: project)
        XCTAssertEqual(result.id, id.uuidString)
    }

    func testRejectsUnsafeIssueLinksWrongIDsAndUnsuccessfulMutations() async throws {
        let id = UUID()
        for data in [
            ["success": true, "issue": issue(UUID())],
            ["success": true, "issue": issue(id, url: "https://example.com/issue/DEV-12")],
            ["success": false, "issue": NSNull()],
        ] as [[String: Any]] {
            let client = try LinearClient(apiKey: "key", transport: { _ in try self.reply(["data": ["issueCreate": data]]) })
            do {
                _ = try await client.createIssue(id: id, title: "Task", description: "Details", teamID: team, projectID: nil)
                XCTFail("Expected rejection")
            } catch LinearError.invalidResponse {} catch LinearError.rejected {}
        }
    }

    @MainActor
    func testPublishesOnlySelectedDraftsAndCheckpointsEachIssue() async throws {
        let original = review(count: 2)
        let selected = original.tasks[1]
        var saved = original
        var requests = 0
        var writes = 0
        let client = try LinearClient(apiKey: "key", transport: { request in
            requests += 1
            XCTAssertEqual(saved.tasks[1].linearExport?.id, selected.id)
            let body = try self.body(request)
            if (body["query"] as? String)?.contains("NutolaIssue(") == true {
                return try self.reply(self.lookup([]))
            }
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            let input = try XCTUnwrap(variables["input"] as? [String: Any])
            let description = try XCTUnwrap(input["description"] as? String)
            XCTAssertTrue(description.contains("Alice @ 0:12"))
            XCTAssertTrue(description.contains(selected.evidence[0].text))
            XCTAssertTrue(description.contains(self.meeting.title))
            XCTAssertFalse(description.contains(original.tasks[0].title))
            return try self.reply(["data": ["issueCreate": ["success": true, "issue": self.issue(selected.id)]]])
        })
        let result = try await LinearTaskPublisher.publish(review: original, selectedIDs: [selected.id], meeting: meeting,
            workspaceID: workspace, teamID: team, projectID: project, client: client, save: { next, previous in
                XCTAssertEqual(saved, previous)
                saved = next
                writes += 1
            })
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(writes, 2)
        XCTAssertNil(result.tasks[0].linearExport)
        XCTAssertEqual(result.tasks[1].linearExport?.identifier, "DEV-12")
        XCTAssertEqual(saved, result)
    }

    @MainActor
    func testLostResponseIsRecoveredByIDWithoutCreatingAnotherIssue() async throws {
        let original = review()
        let id = original.tasks[0].id
        var saved = original
        var mutations = 0
        var created = false
        let client = try LinearClient(apiKey: "key", transport: { request in
            let query = try XCTUnwrap(self.body(request)["query"] as? String)
            if query.contains("mutation") {
                mutations += 1
                created = true
                throw URLError(.timedOut)
            }
            return try self.reply(self.lookup(created ? [self.issue(id)] : []))
        })
        do {
            _ = try await LinearTaskPublisher.publish(review: original, selectedIDs: [id], meeting: meeting,
                workspaceID: workspace, teamID: team, projectID: nil, client: client,
                save: { next, _ in saved = next })
            XCTFail("Expected timeout")
        } catch is URLError {}
        XCTAssertNotNil(saved.tasks[0].linearExport)
        XCTAssertNil(saved.tasks[0].linearExport?.url)
        let result = try await LinearTaskPublisher.publish(review: saved, selectedIDs: [id], meeting: meeting,
            workspaceID: workspace, teamID: team, projectID: nil, client: client,
            save: { next, _ in saved = next })
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(result.tasks[0].linearExport?.identifier, "DEV-12")
    }

    @MainActor
    func testSaveFailurePreventsCreationAndCompletedIssuesAreSkipped() async throws {
        var original = review()
        let id = original.tasks[0].id
        let client = try LinearClient(apiKey: "key", transport: { _ in
            XCTFail("No network request expected")
            throw URLError(.cancelled)
        })
        do {
            _ = try await LinearTaskPublisher.publish(review: original, selectedIDs: [id], meeting: meeting,
                workspaceID: workspace, teamID: team, projectID: nil, client: client,
                save: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            XCTFail("Expected save failure")
        } catch is CocoaError {}
        original.tasks[0].linearExport = LinearIssueExport(id: id, workspaceID: workspace, teamID: team,
            identifier: "DEV-12", url: URL(string: "https://linear.app/work/issue/DEV-12/task")!)
        _ = try await LinearTaskPublisher.publish(review: original, selectedIDs: [id], meeting: meeting,
            workspaceID: workspace, teamID: team, projectID: nil, client: client,
            save: { _, _ in XCTFail("Already published") })
    }

    @MainActor
    func testPendingIssueCannotBeRetriedInAnotherWorkspace() async throws {
        var original = review()
        let id = original.tasks[0].id
        original.tasks[0].linearExport = LinearIssueExport(id: id, workspaceID: "another", teamID: team)
        let client = try LinearClient(apiKey: "key", transport: { _ in XCTFail("Wrong workspace"); throw URLError(.cancelled) })
        do {
            _ = try await LinearTaskPublisher.publish(review: original, selectedIDs: [id], meeting: meeting,
                workspaceID: workspace, teamID: team, projectID: nil, client: client,
                save: { _, _ in XCTFail("Wrong workspace must not modify drafts") })
            XCTFail("Expected wrongWorkspace")
        } catch LinearError.wrongWorkspace {}
    }

    @MainActor
    func testPartialFailureRetainsCompletedLinksAndPendingID() async throws {
        let original = review(count: 2)
        var saved = original
        var mutation = 0
        let client = try LinearClient(apiKey: "key", transport: { request in
            let body = try self.body(request)
            if (body["query"] as? String)?.contains("mutation") != true { return try self.reply(self.lookup([])) }
            mutation += 1
            if mutation == 2 { throw URLError(.networkConnectionLost) }
            return try self.reply(["data": ["issueCreate": ["success": true, "issue": self.issue(original.tasks[0].id)]]])
        })
        do {
            _ = try await LinearTaskPublisher.publish(review: original, selectedIDs: Set(original.tasks.map(\.id)), meeting: meeting,
                workspaceID: workspace, teamID: team, projectID: nil, client: client, save: { next, _ in saved = next })
            XCTFail("Expected partial failure")
        } catch is URLError {}
        XCTAssertNotNil(saved.tasks[0].linearExport?.url)
        XCTAssertEqual(saved.tasks[1].linearExport?.id, original.tasks[1].id)
        XCTAssertNil(saved.tasks[1].linearExport?.url)
    }

    @MainActor
    func testFailureSavingReturnedLinkStillLeavesRecoverablePendingID() async throws {
        let original = review()
        let id = original.tasks[0].id
        var saved = original
        var writes = 0
        var mutations = 0
        var created = false
        let client = try LinearClient(apiKey: "key", transport: { request in
            if (try self.body(request)["query"] as? String)?.contains("mutation") == true {
                mutations += 1
                created = true
                return try self.reply(["data": ["issueCreate": ["success": true, "issue": self.issue(id)]]])
            }
            return try self.reply(self.lookup(created ? [self.issue(id)] : []))
        })
        do {
            _ = try await LinearTaskPublisher.publish(review: original, selectedIDs: [id], meeting: meeting,
                workspaceID: workspace, teamID: team, projectID: nil, client: client, save: { next, _ in
                    writes += 1
                    if writes == 2 { throw CocoaError(.fileWriteNoPermission) }
                    saved = next
                })
            XCTFail("Expected save failure")
        } catch is CocoaError {}
        XCTAssertEqual(saved.tasks[0].linearExport?.id, id)
        XCTAssertNil(saved.tasks[0].linearExport?.url)
        _ = try await LinearTaskPublisher.publish(review: saved, selectedIDs: [id], meeting: meeting,
            workspaceID: workspace, teamID: team, projectID: nil, client: client, save: { next, _ in saved = next })
        XCTAssertEqual(mutations, 1)
        XCTAssertNotNil(saved.tasks[0].linearExport?.url)
    }

    @MainActor
    func testCancellationAfterCheckpointStopsNetworkRequestsAndRetainsRetryID() async throws {
        let original = review()
        let id = original.tasks[0].id
        var saved = original
        let client = try LinearClient(apiKey: "key", transport: { _ in
            XCTFail("Cancelled publishing must not send requests")
            throw URLError(.cancelled)
        })
        let task = Task { @MainActor in
            try await LinearTaskPublisher.publish(review: original, selectedIDs: [id], meeting: meeting,
                workspaceID: workspace, teamID: team, projectID: nil, client: client,
                save: { next, _ in saved = next }, onProgress: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(saved.tasks[0].linearExport?.id, id)
        XCTAssertNil(saved.tasks[0].linearExport?.url)
    }

    func testLegacyDraftsDecodeWithoutLinearMetadata() throws {
        let data = try JSONEncoder().encode(review())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "linearExport")
        json["tasks"] = tasks
        let decoded = try JSONDecoder().decode(DevelopmentTaskReview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.tasks[0].linearExport)
    }
}
