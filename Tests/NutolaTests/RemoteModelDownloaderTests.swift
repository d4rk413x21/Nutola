import Foundation
import Testing
@testable import Nutola

struct RemoteModelDownloaderTests {
    @Test func installationRequiresEveryCompleteManifestFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-model-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = [
            RemoteModelFile(path: "weights.bin", size: 4, isPrimary: true),
            RemoteModelFile(path: "config.json", size: 2, isPrimary: false),
        ]

        #expect(!RemoteModelDownloader.isInstalled(directory: directory, manifest: manifest))
        #expect(RemoteModelDownloader.installedBytes(directory: directory, manifest: manifest) == 0)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4).write(to: directory.appendingPathComponent("weights.bin"))
        #expect(!RemoteModelDownloader.isInstalled(directory: directory, manifest: manifest))

        let config = directory.appendingPathComponent("config.json")
        try Data([0]).write(to: config)
        #expect(!RemoteModelDownloader.isInstalled(directory: directory, manifest: manifest))
        #expect(RemoteModelDownloader.installedBytes(directory: directory, manifest: manifest) == 5)

        try Data([0, 0]).write(to: config)
        #expect(RemoteModelDownloader.isInstalled(directory: directory, manifest: manifest))
        #expect(RemoteModelDownloader.installedBytes(directory: directory, manifest: manifest) == 6)
    }
}
