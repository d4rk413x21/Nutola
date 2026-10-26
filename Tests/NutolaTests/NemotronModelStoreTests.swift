import Foundation
import Testing
@testable import Nutola

struct NemotronModelStoreTests {
    @Test func testManifestContainsNemoArchive() {
        let nemo = NemotronModelStore.manifest.first { $0.isPrimary }
        #expect(nemo != nil)
        #expect(nemo?.path.hasSuffix(".nemo") ?? false)
    }

    @Test func testManifestHasExpectedFileCount() {
        #expect(NemotronModelStore.manifest.count == 6)
    }

    @Test func testTotalSizeIsSumOfManifest() {
        let sum = NemotronModelStore.manifest.reduce(Int64(0)) { $0 + $1.size }
        #expect(NemotronModelStore.totalSize == sum)
    }

    @Test func testTotalSizeIsMultiGB() {
        #expect(NemotronModelStore.totalSize > 2_000_000_000)
    }

    @Test func testFormatBytes() {
        #expect(!(NemotronModelStore.formatBytes(0).isEmpty))
        #expect(NemotronModelStore.formatBytes(1_500_000_000).contains("GB"))
        #expect(!(NemotronModelStore.formatBytes(500).isEmpty))
    }

    @Test func testDirectoryPathUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(NemotronModelStore.directory.path.hasPrefix(appSupport.path))
        #expect(NemotronModelStore.directory.lastPathComponent == "Nemotron")
    }
}
