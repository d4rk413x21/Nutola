import Foundation
import Testing
@testable import Nutola

struct MeetingsCLITests {
    private let id = "123E4567-E89B-12D3-A456-426614174000"

    @Test func testParsesEveryCommand() throws {
        #expect(try MeetingsCLI.parse(arguments: ["help"]) == .help)
        #expect(try MeetingsCLI.parse(arguments: ["list"]) == .list(limit: 20, offset: 0))
        #expect(try MeetingsCLI.parse(arguments: ["list", "--limit", "250", "--offset", "4"]) == .list(limit: 200, offset: 4))
        #expect(try MeetingsCLI.parse(arguments: ["search", "device", "token", "--limit", "5", "--offset", "2"]) == .search(query: "device token", limit: 5, offset: 2))
        #expect(try MeetingsCLI.parse(arguments: ["show", id]) == .show(id: id))
        #expect(try MeetingsCLI.parse(arguments: ["transcript", id]) == .transcript(id: id))
        #expect(try MeetingsCLI.parse(arguments: ["live"]) == .live(minutes: nil))
        #expect(try MeetingsCLI.parse(arguments: ["live", "--minutes", "0"]) == .live(minutes: 0))
    }

    @Test func testMeetingsPrefixAndNoCommandShowHelp() throws {
        #expect(try MeetingsCLI.parse(arguments: []) == .help)
        #expect(try MeetingsCLI.parse(arguments: ["meetings"]) == .help)
        #expect(try MeetingsCLI.parse(arguments: ["meetings", "help"]) == .help)
        #expect(try MeetingsCLI.parse(arguments: ["meetings", "list", "--limit", "3"]) == .list(limit: 3, offset: 0))
    }

    @Test func testRejectsMalformedSyntaxAndValues() {
        assertUsageError(["unknown"], contains: "Unknown meetings command")
        assertUsageError(["list", "--wat"], contains: "Unknown option")
        assertUsageError(["list", "--limit"], contains: "requires a value")
        assertUsageError(["list", "--limit", "many"], contains: "must be an integer")
        assertUsageError(["list", "--offset", "-1"], contains: "must be non-negative")
        assertUsageError(["list", "--limit", "2", "--limit", "3"], contains: "Duplicate option")
        assertUsageError(["search"], contains: "Search query is required")
        assertUsageError(["show"], contains: "Meeting UUID is required")
        assertUsageError(["show", "bad-id"], contains: "must be a meeting UUID")
        assertUsageError(["show", id, "extra"], contains: "Unexpected argument")
        assertUsageError(["transcript", "bad-id"], contains: "must be a meeting UUID")
        assertUsageError(["live", "--minutes", "-2"], contains: "must be non-negative")
    }

    @Test func testSuccessfulRunnerWritesOnlyStdout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-cli-success-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = MeetingArchive(root: root)
        var meeting = Meeting(title: "Daily sync", createdAt: Date())
        meeting.state = .ready
        try archive.createFolder(for: meeting.id)
        try archive.save(meeting)

        var output: [String] = []
        var errors: [String] = []
        let cli = MeetingsCLI(service: MeetingCommandService(archive: archive))

        let status = cli.run(
            arguments: ["list"],
            output: { output.append($0) },
            error: { errors.append($0) }
        )

        #expect(status == 0)
        #expect(errors == [])
        #expect(output.count == 1)
        #expect(output[0].contains("Daily sync"))
    }

    @Test func testHelpWritesOnlyStdout() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-cli-help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var output: [String] = []
        var errors: [String] = []
        let cli = MeetingsCLI(service: MeetingCommandService(archive: MeetingArchive(root: root)))

        let status = cli.run(
            arguments: ["help"],
            output: { output.append($0) },
            error: { errors.append($0) }
        )

        #expect(status == 0)
        #expect(output.joined().contains("Nutola meetings list"))
        #expect(errors == [])
    }

    @Test func testParserFailureWritesUsageToStderrAndReturnsTwo() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-cli-parser-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var output: [String] = []
        var errors: [String] = []
        let cli = MeetingsCLI(service: MeetingCommandService(archive: MeetingArchive(root: root)))

        let status = cli.run(
            arguments: ["list", "--offset", "-1"],
            output: { output.append($0) },
            error: { errors.append($0) }
        )

        #expect(status == 2)
        #expect(output == [])
        #expect(errors.joined().contains("must be non-negative"))
        #expect(errors.joined().contains("Usage:"))
    }

    @Test func testServiceFailureWritesOnlyStderrAndReturnsOne() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-cli-service-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var output: [String] = []
        var errors: [String] = []
        let cli = MeetingsCLI(service: MeetingCommandService(archive: MeetingArchive(root: root)))

        let status = cli.run(
            arguments: ["show", id],
            output: { output.append($0) },
            error: { errors.append($0) }
        )

        #expect(status == 1)
        #expect(output == [])
        #expect(errors == ["Error: No meeting with id \(id)"])
    }

    private func assertUsageError(
        _ arguments: [String],
        contains expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try MeetingsCLI.parse(arguments: arguments)
            Issue.record("Expected a usage error", sourceLocation: sourceLocation)
        } catch {
            #expect(error.localizedDescription.contains(expected), "\(error)", sourceLocation: sourceLocation)
        }
    }
}
