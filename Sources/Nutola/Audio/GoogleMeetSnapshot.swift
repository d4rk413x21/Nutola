import Foundation

struct PlatformParticipant: Codable, Equatable, Sendable {
    var name: String
    var isLocal: Bool
}

/// Value-only representation of the public accessibility tree, also used by fixtures.
struct MeetAccessibilityNode: Codable, Sendable {
    var role: String
    var subrole: String? = nil
    var title: String? = nil
    var description: String? = nil
    var value: String? = nil
    var identifier: String? = nil
    var children: [MeetAccessibilityNode]? = nil

    var label: String { title ?? description ?? "" }
    var isCaptionRegion: Bool {
        subrole == "AXLandmarkRegion" && ["Sottotitoli", "Captions", "Closed captions"].contains(label)
    }
    var isParticipantList: Bool { role == "AXList" && ["Partecipanti", "Participants"].contains(label) }
    var staticTexts: [String] {
        if role == "AXStaticText", let value { return [value] }
        return (children ?? []).flatMap(\.staticTexts)
    }
}

struct GoogleMeetSnapshot: Sendable {
    struct Caption: Equatable, Sendable {
        var id: String
        var name: String
        var text: String
        var isLocal: Bool
    }

    var roomCode: String
    /// Nil means the People panel is closed, not that everyone left.
    var participants: [PlatformParticipant]?
    var captions: [Caption]
    var captionsEnabled: Bool

    static func roomCode(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "meet.google.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil else { return nil }
        return code
    }

    static func parse(_ root: MeetAccessibilityNode, roomCode: String) -> GoogleMeetSnapshot? {
        var nodes: [MeetAccessibilityNode] = []
        func walk(_ node: MeetAccessibilityNode) {
            nodes.append(node)
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)
        // A valid room URL also exists before joining; require the in-call control.
        guard nodes.contains(where: {
            $0.role == "AXButton" && ["Esci dalla chiamata", "Leave call", "Leave the call"].contains($0.label)
        }) else { return nil }

        let people = nodes.first(where: \.isParticipantList)
        let participants = people.map { list in
            (list.children ?? []).compactMap { row -> PlatformParticipant? in
                guard row.role == "AXGroup", let name = validName(row.label) else { return nil }
                let labels = (row.children ?? []).filter { $0.role == "AXStaticText" }.compactMap(\.value)
                let local = labels.dropFirst().contains { ["(Tu)", "(You)"].contains($0) }
                return PlatformParticipant(name: name, isLocal: local)
            }
        }
        let region = nodes.first(where: \.isCaptionRegion)
        let captions = (region?.children ?? []).enumerated().compactMap { index, row -> Caption? in
            let columns = row.children ?? []
            guard columns.count >= 2,
                  let name = validName(columns[0].staticTexts.joined(separator: " ")) else { return nil }
            let text = columns.dropFirst().flatMap(\.staticTexts).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let matches = participants?.filter { $0.name == name } ?? []
            let local = ["Tu", "You"].contains(name) || (!matches.isEmpty && matches.allSatisfy(\.isLocal))
            return Caption(id: row.identifier ?? String(index), name: name, text: text, isLocal: local)
        }
        let enabled = region != nil || nodes.contains {
            $0.role == "AXButton" && ["Disattiva sottotitoli", "Turn off captions"].contains($0.label)
        }
        return GoogleMeetSnapshot(roomCode: roomCode, participants: participants, captions: captions,
                                  captionsEnabled: enabled)
    }

    private static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}
