import Foundation
import Testing
@testable import Nutola

@MainActor
final class ImportAudioUseCaseTests {
    private var tempDir: URL!
    private var testAudioURL: URL!

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testAudioURL = tempDir.appendingPathComponent("sample.wav")
        try Self.makeSilentWAV(at: testAudioURL, durationSeconds: 1.0)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Write a minimal 16-bit PCM WAV file with `durationSeconds` of silence.
    /// No recording permission, no AVAssetWriter race — pure byte writing.
    private static func makeSilentWAV(at url: URL, durationSeconds: Double) throws {
        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let totalSamples = UInt32(sampleRate) * UInt32(durationSeconds)
        let dataSize = totalSamples * UInt32(bitsPerSample / 8) * UInt32(channels)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: UInt32(36 + dataSize).leBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: UInt32(16).leBytes)  // fmt chunk size
        data.append(contentsOf: UInt16(1).leBytes)   // PCM format
        data.append(contentsOf: channels.leBytes)
        data.append(contentsOf: sampleRate.leBytes)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = UInt32(channels) * UInt32(bitsPerSample) / 8
        data.append(contentsOf: byteRate.leBytes)
        data.append(contentsOf: UInt16(blockAlign).leBytes)
        data.append(contentsOf: bitsPerSample.leBytes)
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: dataSize.leBytes)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        try data.write(to: url)
    }

    private func makeUseCase(
        meetings: MockMeetingRepository,
        folders: MeetingFolderStore,
        settings: MockSettingsRepository = MockSettingsRepository()
    ) -> (ImportAudioUseCase, MockProcessingService) {
        let processing = MockProcessingService()
        let processUC = ProcessMeetingUseCase(
            meetingRepository: meetings,
            processingService: processing,
            notificationService: MockNotificationService())
        let useCase = ImportAudioUseCase(
            meetingRepository: meetings,
            folderRepository: folders,
            processMeeting: processUC,
            settings: settings)
        return (useCase, processing)
    }

    private func makeFolders() -> MeetingFolderStore {
        MeetingFolderStore(archive: FolderArchive(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ImportAudio-Folders-\(UUID().uuidString)", isDirectory: true)))
    }

    @Test func testImportCreatesMeetingAndCallsPipeline() async throws {
        let meetings = MockMeetingRepository()
        let (useCase, processing) = makeUseCase(
            meetings: meetings, folders: makeFolders())

        let id = try await useCase.execute(fileURL: testAudioURL, title: "Imported Chat")
        let saved = meetings.meeting(id: id)
        #expect(saved != nil, "Imported meeting should be saved")
        #expect(saved?.title == "Imported Chat")
        #expect(saved?.sourceApp == "Audio Import")
        #expect(FileManager.default.fileExists(
            atPath: meetings.archive.systemURL(for: id).path), "Audio file should be copied to the archive")
        #expect(processing.processCallCount == 1, "Pipeline should run once")
    }

    @Test func testImportUsesFileNameWhenTitleNil() async throws {
        let meetings = MockMeetingRepository()
        let (useCase, _) = makeUseCase(meetings: meetings, folders: makeFolders())

        let id = try await useCase.execute(fileURL: testAudioURL)
        let saved = meetings.meeting(id: id)
        #expect(saved?.title == "sample", "Default title = file name without extension")
    }

    @Test func testImportRejectsUnsupportedFormat() async throws {
        let meetings = MockMeetingRepository()
        let (useCase, _) = makeUseCase(meetings: meetings, folders: makeFolders())

        let badURL = tempDir.appendingPathComponent("file.txt")
        try Data("not audio".utf8).write(to: badURL)
        do {
            _ = try await useCase.execute(fileURL: badURL)
            Issue.record("Expected import to fail for .txt")
        } catch {
            #expect(error is ImportError)
        }
    }

    @Test func testImportRejectsMissingFile() async {
        let meetings = MockMeetingRepository()
        let (useCase, _) = makeUseCase(meetings: meetings, folders: makeFolders())

        let missingURL = tempDir.appendingPathComponent("nope.m4a")
        do {
            _ = try await useCase.execute(fileURL: missingURL)
            Issue.record("Expected import to fail for missing file")
        } catch {
            #expect(error is ImportError)
        }
    }
}

private extension FixedWidthInteger {
    var leBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}
