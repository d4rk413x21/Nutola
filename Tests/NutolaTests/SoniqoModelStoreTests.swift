import Foundation
import Testing
@testable import Nutola

struct SoniqoModelStoreTests {
    @Test func testStreamingManifestHasCoreMLBundles() {
        let manifest = SoniqoModel.parakeetStreaming.manifest
        #expect(manifest.count == 14)
        #expect(manifest.contains { $0.path == "encoder.mlmodelc/weights/weight.bin" && $0.isPrimary })
    }

    @Test func testBatchManifestHasMultipleEncoders() {
        let manifest = SoniqoModel.parakeetBatch.manifest
        #expect(manifest.count == 25)
        #expect(manifest.contains { $0.path.hasPrefix("encoder_5s.mlmodelc/") })
        #expect(manifest.contains { $0.path.hasPrefix("encoder_15s.mlmodelc/") })
    }

    @Test func testStreamingTotalSizeNear120MB() {
        let total = SoniqoModelStore.totalSize(.parakeetStreaming)
        #expect(total > 100_000_000)
        #expect(total < 130_000_000)
    }

    @Test func testBatchTotalSizeIsLarge() {
        let total = SoniqoModelStore.totalSize(.parakeetBatch)
        #expect(total > 1_700_000_000)
    }

    @Test func testLanguageCoverageIncludesPortuguese() {
        #expect(SoniqoModel.languageCodes.contains("pt"))
        #expect(SoniqoModel.languageCodes.contains("en"))
    }

    @Test func testDirectoryPathUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = SoniqoModelStore.directory(for: .parakeetStreaming)
        #expect(dir.path.hasPrefix(appSupport.path))
        #expect(dir.path.contains("Soniqo"))
    }
}
