import Foundation

@MainActor
enum LinearTaskPublisher {
    static func publish(
        review: DevelopmentTaskReview, selectedIDs: Set<UUID>, meeting: Meeting,
        workspaceID: String, teamID: String, projectID: String?, client: LinearClient,
        save: (DevelopmentTaskReview, DevelopmentTaskReview) throws -> Void,
        onProgress: (DevelopmentTaskReview) -> Void = { _ in }
    ) async throws -> DevelopmentTaskReview {
        var current = review
        for index in current.tasks.indices where selectedIDs.contains(current.tasks[index].id) {
            try Task.checkCancellation()
            let draft = current.tasks[index]
            if draft.linearExport?.url != nil { continue }
            guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.evidence.isEmpty else { throw LinearError.invalidDraft }
            if let pending = draft.linearExport, pending.workspaceID != workspaceID { throw LinearError.wrongWorkspace }
            let previous = current
            // The draft UUID stays stable even if the response is lost or another window retries.
            current.tasks[index].linearExport = LinearIssueExport(
                id: draft.linearExport?.id ?? draft.id, workspaceID: workspaceID, teamID: teamID, projectID: projectID)
            try save(current, previous)
            onProgress(current)
            let id = current.tasks[index].linearExport!.id
            let existing = try await client.issue(id: id, workspaceID: workspaceID)
            let issue: LinearIssue
            if let existing {
                issue = existing
            } else {
                let description = DevelopmentTaskReview(tasks: [draft]).markdown(meeting: meeting, selectedIDs: [draft.id])
                issue = try await client.createIssue(id: id, title: draft.title, description: description,
                                                     teamID: teamID, projectID: projectID)
            }
            let pending = current
            current.tasks[index].linearExport = LinearIssueExport(
                id: id, workspaceID: workspaceID, teamID: issue.team.id, projectID: issue.project?.id,
                identifier: issue.identifier, url: issue.url)
            try save(current, pending)
            onProgress(current)
        }
        return current
    }
}
