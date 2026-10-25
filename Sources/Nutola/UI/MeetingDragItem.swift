import SwiftUI
import UniformTypeIdentifiers

struct MeetingDragItem: Transferable, Codable {
    let meetingID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .meetingDrag)
    }
}

extension UTType {
    static let meetingDrag = UTType(exportedAs: "io.github.d4rk413x21.nutola.meeting-drag")
}
