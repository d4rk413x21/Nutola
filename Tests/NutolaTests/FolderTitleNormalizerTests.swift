import Foundation
import Testing
@testable import Nutola

struct FolderTitleNormalizerTests {
    @Test func testTrimsAndLowercases() {
        #expect(FolderTitleNormalizer.key(for: "Identity Intelligence Eng Standup") == "identity intelligence eng standup")
    }

    @Test func testCollapsesWhitespace() {
        #expect(FolderTitleNormalizer.key(for: "  Weekly  1:1  ") == "weekly 1:1")
    }

    @Test func testEmptyString() {
        #expect(FolderTitleNormalizer.key(for: "   ") == "")
    }
}
