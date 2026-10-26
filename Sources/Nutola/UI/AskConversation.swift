import Foundation

struct AskConversation {
    var messages: [AskChatMessage] = []
    private(set) var activeResponseID: UUID?
    var isAnswering: Bool { activeResponseID != nil }

    mutating func beginResponse() -> UUID {
        cancelResponse()
        let id = UUID()
        activeResponseID = id
        messages.append(AskChatMessage(id: id, role: .assistant, text: "", isLoading: true))
        return id
    }

    @discardableResult
    mutating func updateResponse(_ id: UUID, text: String, finished: Bool = false, isError: Bool = false) -> Bool {
        guard activeResponseID == id, let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages[index] = AskChatMessage(id: id, role: .assistant, text: text,
                                         isLoading: !finished && text.isEmpty, isError: isError)
        if finished { activeResponseID = nil }
        return true
    }

    @discardableResult
    mutating func cancelResponse(_ id: UUID? = nil) -> Bool {
        guard let active = activeResponseID, id == nil || id == active else { return false }
        messages.removeAll { $0.id == active }
        activeResponseID = nil
        return true
    }
}

struct AskChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    var isLoading: Bool
    var isError: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isLoading: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isLoading = isLoading
        self.isError = isError
    }
}
