import Foundation
import Testing
@testable import Nutola

final class MCPServerTests {
    var tmp: URL!
    var archive: MeetingArchive!
    var templates: TemplateStore!
    var server: MCPServer!
    var meeting: Meeting!

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-mcp-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
        templates = TemplateStore(root: tmp)
        server = MCPServer(archive: archive, templates: templates)

        var m = Meeting(title: "Roadmap sync", createdAt: Date())
        m.speakers = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Priya")]
        m.duration = 1800
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "s1", start: 12, end: 15, text: "Let's move launch to March.")],
            for: m.id
        )
        try archive.saveSummary("## TL;DR\nLaunch moved to March.", for: m.id)
        meeting = m
    }

    deinit {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let line = String(
            data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        guard let response = server.handle(line: line) else { return [:] }
        return try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
    }

    @Test func testInitializeEchoesSupportedVersion() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let serverInfo = result["serverInfo"] as! [String: Any]
        #expect(serverInfo["name"] as? String == "nutola")
        #expect((result["capabilities"] as! [String: Any])["tools"] != nil)
    }

    @Test func testInitializeOffersLatestForUnknownVersion() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "1999-01-01", "capabilities": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["protocolVersion"] as? String == MCPServer.supportedProtocolVersions[0])
    }

    @Test func testUnknownToolIsProtocolError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 10, "method": "tools/call",
            "params": ["name": "explode", "arguments": [:]],
        ])
        let error = resp["error"] as! [String: Any]
        #expect(error["code"] as? Int == -32602)
    }

    @Test func testInitializedNotificationGetsNoResponse() {
        let response = server.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(response == nil)
    }

    @Test func testToolsList() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (resp["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = tools.map { $0["name"] as! String }.sorted()
        #expect(names == [
            "create_template", "delete_meeting", "delete_template", "get_live_transcript", "get_meeting",
            "get_template", "get_transcript", "list_meetings", "list_templates",
            "regenerate_summary", "rename_template", "search_meetings", "update_summary",
            "update_template",
        ])
        for tool in tools {
            #expect(tool["description"] != nil)
            #expect(tool["inputSchema"] != nil)
        }
    }

    @Test func testListMeetingsCall() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == false)
        let content = result["content"] as! [[String: Any]]
        let text = content[0]["text"] as! String
        #expect(text.contains("Roadmap sync"))
        #expect(text.contains(meeting.id.uuidString))
    }

    @Test func testSearchAndGetTranscript() throws {
        let search = try roundTrip([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "search_meetings", "arguments": ["query": "march launch"]],
        ])
        let searchText = (((search["result"] as! [String: Any])["content"]
            as! [[String: Any]])[0]["text"] as! String)
        #expect(searchText.contains("Roadmap sync"))

        let transcript = try roundTrip([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "get_transcript", "arguments": ["id": meeting.id.uuidString]],
        ])
        let text = (((transcript["result"] as! [String: Any])["content"]
            as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("Priya @ 0:12: Let's move launch to March."))
    }

    @Test func testGetMeetingIncludesSummary() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "get_meeting", "arguments": ["id": meeting.id.uuidString]],
        ])
        let text = (((resp["result"] as! [String: Any])["content"]
            as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("Launch moved to March."))
        #expect(text.contains("Priya"))
    }

    @Test func testReadToolsMatchSharedMeetingService() throws {
        let reads = MeetingCommandService(archive: archive)
        let cases: [(String, [String: Any], String)] = [
            ("list_meetings", [:], reads.list(limit: 20, offset: 0)),
            ("search_meetings", ["query": "march"], try reads.search(query: "march", limit: 20, offset: 0)),
            ("get_meeting", ["id": meeting.id.uuidString], try reads.show(id: meeting.id.uuidString)),
            ("get_transcript", ["id": meeting.id.uuidString], try reads.transcript(id: meeting.id.uuidString)),
            ("get_live_transcript", [:], reads.live(minutes: nil)),
        ]

        for (index, value) in cases.enumerated() {
            let response = try roundTrip([
                "jsonrpc": "2.0", "id": 100 + index, "method": "tools/call",
                "params": ["name": value.0, "arguments": value.1],
            ])
            let result = response["result"] as! [String: Any]
            let content = result["content"] as! [[String: Any]]
            #expect(content[0]["text"] as? String == value.2, "\(value.0)")
        }
    }

    @Test func testToolErrorsAreSoft() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "get_meeting", "arguments": ["id": UUID().uuidString]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == true)
    }

    @Test func testUnknownMethodIsJSONRPCError() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 8, "method": "resources/list"])
        let error = resp["error"] as! [String: Any]
        #expect(error["code"] as? Int == -32601)
    }

    @Test func testParseError() {
        let resp = server.handle(line: "not json")
        #expect(resp!.contains("-32700"))
    }

    @Test func testPing() throws {
        let resp = try roundTrip(["jsonrpc": "2.0", "id": 9, "method": "ping"])
        #expect(resp["result"] != nil)
    }

    @Test func testListTemplatesReflectsSeededBuiltins() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 20, "method": "tools/call",
            "params": ["name": "list_templates", "arguments": [:]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == false)
        let text = (((result)["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("Meeting Notes"))
        #expect(text.contains("1-on-1"))
        #expect(text.contains("Interview"))
    }

    @Test func testCreateTemplateHappyPath() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 21, "method": "tools/call",
            "params": [
                "name": "create_template",
                "arguments": ["name": "Standup", "content": "# {{title}}\n\n## Blockers\nWhat's stuck."],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == false)
        #expect(templates.template(named: "Standup") != nil)
    }

    @Test func testCreateTemplateCollisionIsError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 22, "method": "tools/call",
            "params": [
                "name": "create_template",
                "arguments": ["name": "meeting notes", "content": "# {{title}}"],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == true)
    }

    @Test func testUpdateTemplateOnMissingNameIsError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 23, "method": "tools/call",
            "params": [
                "name": "update_template",
                "arguments": ["name": "Does Not Exist", "content": "# {{title}}"],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == true)
    }

    @Test func testGetTemplateRoundTrip() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 24, "method": "tools/call",
            "params": ["name": "get_template", "arguments": ["name": "Interview"]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == false)
        let text = (((result)["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("## Candidate Snapshot"))
    }

    @Test func testDeleteTemplateReflectedInList() throws {
        let delete = try roundTrip([
            "jsonrpc": "2.0", "id": 25, "method": "tools/call",
            "params": ["name": "delete_template", "arguments": ["name": "1-on-1"]],
        ])
        #expect((delete["result"] as! [String: Any])["isError"] as? Bool == false)

        let list = try roundTrip([
            "jsonrpc": "2.0", "id": 26, "method": "tools/call",
            "params": ["name": "list_templates", "arguments": [:]],
        ])
        let text = (((list["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(!(text.contains("1-on-1")))
    }

    @Test func testRenameTemplateCaseOnly() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 27, "method": "tools/call",
            "params": [
                "name": "rename_template",
                "arguments": ["old_name": "Interview", "new_name": "interview"],
            ],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == false)
        #expect(templates.template(named: "interview")?.name == "interview")
    }

    // MARK: - get_live_transcript

    private func startRecordingMeeting(
        title: String, live segments: [TranscriptSegment]
    ) throws -> Meeting {
        var m = Meeting(title: title, createdAt: Date())
        m.state = .recording
        try archive.createFolder(for: m.id)
        try archive.save(m)
        archive.saveLiveTranscript(segments, for: m.id)
        return m
    }

    @Test func testLiveTranscriptWhenNothingRecording() {
        // setUp's fixture meeting is .ready, not .recording.
        #expect(MCPServer.liveTranscriptText(archive: archive) == "No meeting is being recorded right now.")
    }

    @Test func testLiveTranscriptReturnsInProgressMeeting() throws {
        _ = try startRecordingMeeting(title: "Standup", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 1, end: 1, text: "Morning everyone."),
            TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 3, end: 3, text: "Hi, ready to start."),
        ])
        let text = MCPServer.liveTranscriptText(archive: archive)
        #expect(text.contains("Standup"))
        #expect(text.contains("You @"))
        #expect(text.contains("Morning everyone."))
        #expect(text.contains("Others @"))
        #expect(text.contains("real-time approximation"))
    }

    @Test func testLiveTranscriptRecordingButEmpty() throws {
        _ = try startRecordingMeeting(title: "Quiet", live: [])
        #expect(MCPServer.liveTranscriptText(archive: archive).contains("nothing has been transcribed yet"))
    }

    @Test func testLiveTranscriptStaleFileIgnored() throws {
        _ = try startRecordingMeeting(title: "Orphan", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 0, end: 0, text: "hello"),
        ])
        // A crash-orphaned .recording meeting: live.json older than 60s isn't "live".
        #expect(MCPServer.liveTranscriptText(archive: archive, now: Date().addingTimeInterval(120)) == "No meeting is being recorded right now.")
    }

    @Test func testLiveTranscriptWindowsToRecentByDefault() throws {
        _ = try startRecordingMeeting(title: "Long call", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 0, end: 0, text: "Ancient history."),
            TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 600, end: 600, text: "Recent point."),
        ])
        let text = MCPServer.liveTranscriptText(archive: archive)
        #expect(text.contains("Recent point."))
        #expect(!(text.contains("Ancient history.")))
        #expect(text.contains("last \(MCPServer.liveDefaultWindowMinutes) minutes"))
        #expect(text.contains("1-2 sentences")) // brevity steering present
    }

    @Test func testLiveTranscriptMinutesZeroReturnsWholeMeeting() throws {
        _ = try startRecordingMeeting(title: "Long call", live: [
            TranscriptSegment(speakerID: LiveTranscriber.youSpeakerID, start: 0, end: 0, text: "Ancient history."),
            TranscriptSegment(speakerID: LiveTranscriber.othersSpeakerID, start: 600, end: 600, text: "Recent point."),
        ])
        let text = MCPServer.liveTranscriptText(archive: archive, minutes: 0)
        #expect(text.contains("Ancient history."))
        #expect(text.contains("Recent point."))
    }

    // MARK: - update_summary / regenerate_summary

    @Test func testUpdateSummaryWritesNotes() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 30, "method": "tools/call",
            "params": ["name": "update_summary", "arguments": [
                "id": meeting.id.uuidString, "content": "## New\nRewritten notes.",
            ]],
        ])
        #expect((resp["result"] as! [String: Any])["isError"] as? Bool == false)
        #expect(archive.summary(for: meeting.id) == "## New\nRewritten notes.")
    }

    @Test func testUpdateSummaryRequiresContent() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 31, "method": "tools/call",
            "params": ["name": "update_summary", "arguments": ["id": meeting.id.uuidString]],
        ])
        #expect((resp["result"] as! [String: Any])["isError"] as? Bool == true)
    }

    @Test func testRegenerateSummaryWithoutTranscriptErrors() throws {
        var m = Meeting(title: "Empty", createdAt: Date())
        m.state = .ready
        try archive.createFolder(for: m.id)
        try archive.save(m)
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 32, "method": "tools/call",
            "params": ["name": "regenerate_summary", "arguments": ["id": m.id.uuidString]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == true)
        let text = ((result["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("no transcript"))
    }

    @Test func testRegenerateSummaryUnknownTemplateErrors() throws {
        // The fixture meeting HAS a transcript, but an unknown template is rejected
        // before summarization is ever attempted (so this stays deterministic).
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 33, "method": "tools/call",
            "params": ["name": "regenerate_summary", "arguments": [
                "id": meeting.id.uuidString, "template": "Nonexistent Template",
            ]],
        ])
        #expect((resp["result"] as! [String: Any])["isError"] as? Bool == true)
    }

    // MARK: - list_meetings pagination

    @Test func testListMeetingsPaginatesWithOffset() throws {
        // Seed 3 more meetings (4 total incl. setUp's), newest first.
        for i in 0..<3 {
            var m = Meeting(title: "Sync \(i)", createdAt: Date().addingTimeInterval(TimeInterval(i)))
            m.state = .ready
            try archive.createFolder(for: m.id)
            try archive.save(m)
        }
        let page1 = try roundTrip([
            "jsonrpc": "2.0", "id": 40, "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": ["limit": 2, "offset": 0]],
        ])
        let text1 = (((page1["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text1.contains("next_offset: 2"), "first page should hint at more")

        let page2 = try roundTrip([
            "jsonrpc": "2.0", "id": 41, "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": ["limit": 2, "offset": 2]],
        ])
        let text2 = (((page2["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        // Last page: no next_offset hint.
        #expect(!(text2.contains("next_offset")))
    }

    @Test func testListMeetingsOffsetBeyondEndIsExplicit() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 42, "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": ["limit": 20, "offset": 999]],
        ])
        let text = (((resp["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("No more meetings"))
    }

    // MARK: - delete_meeting

    @Test func testDeleteMeetingRemovesIt() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 43, "method": "tools/call",
            "params": ["name": "delete_meeting", "arguments": ["id": meeting.id.uuidString]],
        ])
        let result = resp["result"] as! [String: Any]
        #expect(result["isError"] as? Bool == false)
        let text = ((result["content"] as! [[String: Any]])[0]["text"] as! String)
        #expect(text.contains("Deleted"))
        #expect(archive.meeting(id: meeting.id) == nil)
    }

    @Test func testDeleteMeetingUnknownIdIsError() throws {
        let resp = try roundTrip([
            "jsonrpc": "2.0", "id": 44, "method": "tools/call",
            "params": ["name": "delete_meeting", "arguments": ["id": UUID().uuidString]],
        ])
        #expect((resp["result"] as! [String: Any])["isError"] as? Bool == true)
    }
}
