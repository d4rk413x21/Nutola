import Foundation

enum LinearError: LocalizedError {
    case invalidKey, invalidResponse, rejected, wrongWorkspace, invalidDraft
    case http(Int)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter a valid Linear personal API key in Settings → Integrations."
        case .invalidResponse: "Linear returned an unexpected response. Retry to recover any issue already created."
        case .rejected: "Linear rejected the request. Check the API key permissions and selected team/project, then retry."
        case .wrongWorkspace: "This draft has a pending issue in another Linear workspace. Reconnect that workspace to retry."
        case .invalidDraft: "Each selected task needs a title, description and transcript evidence."
        case .http(let status):
            switch status {
            case 401, 403: "Linear access was denied. Check the API key and its permissions."
            case 429: "Linear is rate limiting requests. Wait a little, then retry."
            default: "Linear request failed (HTTP \(status)). Retry to recover any issue already created."
            }
        case .keychain(let status): "Could not access the macOS Keychain (status \(status))."
        }
    }
}

struct LinearWorkspace: Codable, Equatable { let id: String; let name: String }
struct LinearTeam: Codable, Identifiable { let id: String; let name: String; let key: String }
struct LinearProject: Codable, Identifiable { let id: String; let name: String }
struct LinearIssue: Codable, Equatable {
    struct Reference: Codable, Equatable { let id: String }
    let id: String
    let identifier: String
    let url: URL
    let team: Reference
    let project: Reference?
}

struct LinearIssueExport: Codable, Equatable, Sendable {
    let id: UUID
    let workspaceID: String
    var teamID: String
    var projectID: String?
    var identifier: String?
    var url: URL?
}

struct LinearClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let apiKey: String
    private let transport: Transport
    private static let session = URLSession(configuration: .ephemeral)

    init(apiKey: String, transport: Transport? = nil) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw LinearError.invalidKey
        }
        self.apiKey = key
        self.transport = transport ?? { request in
            let (data, response) = try await LinearClient.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LinearError.invalidResponse }
            return (data, response)
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let message: String }
        let data: T?
        let errors: [Failure]?
    }
    private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    private struct Connection<T: Decodable>: Decodable { let nodes: [T]; let pageInfo: PageInfo }
    private struct TeamsData: Decodable { let organization: LinearWorkspace; let teams: Connection<LinearTeam> }
    private struct ProjectsData: Decodable {
        struct Team: Decodable { let projects: Connection<LinearProject> }
        let team: Team
    }
    private struct IssuesData: Decodable {
        struct Issues: Decodable { let nodes: [LinearIssue] }
        let organization: LinearWorkspace
        let issues: Issues
    }
    private struct CreateData: Decodable {
        struct Payload: Decodable { let success: Bool; let issue: LinearIssue? }
        let issueCreate: Payload
    }

    private func request<T: Decodable>(_ query: String, variables: [String: Any] = [:]) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw LinearError.http(response.statusCode) }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { throw LinearError.invalidResponse }
        guard envelope.errors?.isEmpty != false else { throw LinearError.rejected }
        guard let result = envelope.data else { throw LinearError.invalidResponse }
        return result
    }

    private func nextCursor(_ page: PageInfo, seen: inout Set<String>) throws -> String? {
        guard page.hasNextPage else { return nil }
        guard let cursor = page.endCursor, !cursor.isEmpty, seen.insert(cursor).inserted else { throw LinearError.invalidResponse }
        return cursor
    }

    func teams() async throws -> (workspace: LinearWorkspace, teams: [LinearTeam]) {
        var teams: [LinearTeam] = []
        var workspace: LinearWorkspace?
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            let data: TeamsData = try await request("""
                query NutolaTeams($after: String) {
                  organization { id name }
                  teams(first: 50, after: $after) { nodes { id name key } pageInfo { hasNextPage endCursor } }
                }
                """, variables: ["after": cursor as Any? ?? NSNull()])
            if let workspace, workspace.id != data.organization.id { throw LinearError.wrongWorkspace }
            workspace = data.organization
            teams += data.teams.nodes
            cursor = try nextCursor(data.teams.pageInfo, seen: &seen)
        } while cursor != nil
        guard let workspace else { throw LinearError.invalidResponse }
        return (workspace, teams.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func projects(teamID: String) async throws -> [LinearProject] {
        var projects: [LinearProject] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            let data: ProjectsData = try await request("""
                query NutolaProjects($team: String!, $after: String) {
                  team(id: $team) {
                    projects(first: 50, after: $after) { nodes { id name } pageInfo { hasNextPage endCursor } }
                  }
                }
                """, variables: ["team": teamID, "after": cursor as Any? ?? NSNull()])
            projects += data.team.projects.nodes
            cursor = try nextCursor(data.team.projects.pageInfo, seen: &seen)
        } while cursor != nil
        return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let issueFields = "id identifier url team { id } project { id }"

    func issue(id: UUID, workspaceID: String) async throws -> LinearIssue? {
        let data: IssuesData = try await request("""
            query NutolaIssue($id: ID!) {
              organization { id name }
              issues(first: 1, includeArchived: true, filter: {id: {eq: $id}}) { nodes { \(Self.issueFields) } }
            }
            """, variables: ["id": id.uuidString])
        guard data.organization.id == workspaceID else { throw LinearError.wrongWorkspace }
        if let issue = data.issues.nodes.first { try validate(issue, id: id) }
        return data.issues.nodes.first
    }

    func createIssue(id: UUID, title: String, description: String, teamID: String, projectID: String?) async throws -> LinearIssue {
        var input: [String: Any] = ["id": id.uuidString, "title": title, "description": description, "teamId": teamID]
        if let projectID { input["projectId"] = projectID }
        let data: CreateData = try await request("""
            mutation NutolaCreateIssue($input: IssueCreateInput!) {
              issueCreate(input: $input) { success issue { \(Self.issueFields) } }
            }
            """, variables: ["input": input])
        guard data.issueCreate.success, let issue = data.issueCreate.issue else { throw LinearError.rejected }
        try validate(issue, id: id)
        return issue
    }

    private func validate(_ issue: LinearIssue, id: UUID) throws {
        guard UUID(uuidString: issue.id) == id, !issue.identifier.isEmpty,
              issue.url.scheme == "https", issue.url.host == "linear.app", issue.url.path.contains("/issue/") else {
            throw LinearError.invalidResponse
        }
    }
}
