import Foundation
import XCTest
@testable import Nutola

final class TranscriptionLocalesTests: XCTestCase {
    func testItalianIsPreferredForAutomaticTranscription() {
        let ids = TranscriptionLocales.primaryCandidateIdentifiers()
        XCTAssertEqual(ids.first, "it-IT")
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testItalianAndFallbackAssetsIncluded() {
        let ids = TranscriptionLocales.assetCandidateIdentifiers()
        XCTAssertTrue(ids.contains("it-IT"))
        XCTAssertTrue(ids.contains("en-US"))
        XCTAssertTrue(ids.contains("pt-BR"))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testReadsPerMeetingLocaleFromArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-locale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("TranscriptionLocales", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let meetingID = UUID()
        let mapping = [meetingID.uuidString: "it-IT"]
        let data = try JSONEncoder().encode(mapping)
        try data.write(to: dir.appendingPathComponent("overrides.json"))

        XCTAssertEqual(
            TranscriptionLocales.storedLocale(forMeetingID: meetingID, root: root)?
                .identifier(.bcp47),
            "it-IT"
        )
        XCTAssertNil(TranscriptionLocales.storedLocale(forMeetingID: UUID(), root: root))
    }
}
