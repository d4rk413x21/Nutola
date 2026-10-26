import Foundation
import Testing
@testable import Nutola

struct TranscriptionLocalesTests {
    @Test func testItalianIsPreferredForAutomaticTranscription() {
        let ids = TranscriptionLocales.primaryCandidateIdentifiers()
        #expect(ids.first == "it-IT")
        #expect(Set(ids).count == ids.count)
    }

    @Test func testItalianAndFallbackAssetsIncluded() {
        let ids = TranscriptionLocales.assetCandidateIdentifiers()
        #expect(ids.contains("it-IT"))
        #expect(ids.contains("en-US"))
        #expect(ids.contains("pt-BR"))
        #expect(Set(ids).count == ids.count)
    }

    @Test func testReadsPerMeetingLocaleFromArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-locale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("TranscriptionLocales", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let meetingID = UUID()
        let mapping = [meetingID.uuidString: "it-IT"]
        let data = try JSONEncoder().encode(mapping)
        try data.write(to: dir.appendingPathComponent("overrides.json"))

        #expect(TranscriptionLocales.storedLocale(forMeetingID: meetingID, root: root)?
                .identifier(.bcp47) == "it-IT")
        #expect(TranscriptionLocales.storedLocale(forMeetingID: UUID(), root: root) == nil)
    }
}
