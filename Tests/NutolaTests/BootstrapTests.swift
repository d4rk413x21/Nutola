import Foundation
import Testing
@testable import Nutola

struct BootstrapTests {
    @Test func testNoArgumentsRouteToGUI() {
        #expect(Bootstrap.route(arguments: []) == .app)
    }

    @Test func testVersionAndMCPRetainExistingRouting() {
        #expect(Bootstrap.route(arguments: ["--version"]) == .version)
        #expect(Bootstrap.route(arguments: ["--mcp"]) == .mcp)
        #expect(Bootstrap.route(arguments: ["ignored", "--version"]) == .version)
        #expect(Bootstrap.route(arguments: ["ignored", "--mcp"]) == .mcp)
    }

    @Test func testMeetingsPrefixRoutesToCLI() {
        #expect(Bootstrap.route(arguments: ["meetings"]) == .meetings(arguments: ["meetings"]))
        #expect(Bootstrap.route(arguments: ["meetings", "list", "--limit", "3"]) == .meetings(arguments: ["meetings", "list", "--limit", "3"]))
    }

    @Test func testExistingFlagsTakePrecedenceOverMeetings() {
        #expect(Bootstrap.route(arguments: ["meetings", "--version"]) == .version)
        #expect(Bootstrap.route(arguments: ["meetings", "--mcp"]) == .mcp)
    }

    @Test func testUnrelatedArgumentsKeepLaunchingGUI() {
        #expect(Bootstrap.route(arguments: ["unexpected"]) == .app)
        #expect(Bootstrap.route(arguments: ["--legacy-flag"]) == .app)
    }
}
