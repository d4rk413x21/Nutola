import Foundation

/// One binary, two personalities:
///   Nutola          → the menu bar app
///   Nutola --mcp    → an MCP stdio server over the meeting archive
///   Nutola --version
@main
enum Bootstrap {
    static var version: String { AppVersion.displayVersion ?? "development" }

    enum Route: Equatable {
        case version
        case mcp
        case meetings(arguments: [String])
        case app
    }

    static func route(arguments: [String]) -> Route {
        if arguments.contains("--version") { return .version }
        if arguments.contains("--mcp") { return .mcp }
        if arguments.first == "meetings" { return .meetings(arguments: arguments) }
        return .app
    }

    static func main() {
        // A claude/gh subprocess (or the MCP client) exiting before draining a
        // pipe would otherwise SIGPIPE-kill the whole app mid-recording.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let destination = route(arguments: arguments)
        if destination == .app, Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier {
            AppIdentity.importPreviousPreferences()
        }
        // Opt-in crash handlers (no-op unless AppSettings.crashDiagnostics is on).
        // Installed before NutolaApp.main() so an early crash is still captured.
        CrashDiagnosticLog.install()
        switch destination {
        case .version:
            print("nutola \(version)")
        case .mcp:
            MCPServer(archive: MeetingArchive(), templates: TemplateStore()).runBlocking()
        case .meetings(let arguments):
            let cli = MeetingsCLI(service: MeetingCommandService(archive: MeetingArchive()))
            let status = cli.run(
                arguments: arguments,
                output: { write($0, to: .standardOutput) },
                error: { write($0, to: .standardError) }
            )
            if status != 0 { exit(status) }
        case .app:
            NutolaApp.main()
        }
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data((text + "\n").utf8))
    }
}
