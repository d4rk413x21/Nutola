import Foundation
import SwiftUI

@MainActor
final class MeetingFolderStore: ObservableObject {
    let archive: FolderArchive
    @Published private(set) var folders: [MeetingFolder] = []
    @Published private(set) var titleRules: [FolderTitleRule] = []

    init(archive: FolderArchive = FolderArchive()) {
        self.archive = archive
        reload()
    }

    func reload() {
        folders = archive.allFolders()
        titleRules = archive.allTitleRules()
    }

    @discardableResult
    func createFolder(
        name: String,
        description: String? = nil,
        iconKind: FolderIconKind = .symbol,
        iconValue: String = "folder.fill",
        iconColorHex: String = "#3FB27F"
    ) -> MeetingFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = MeetingFolder(
            name: trimmed.isEmpty ? "New folder" : trimmed,
            description: (trimmedDesc?.isEmpty == false) ? trimmedDesc : nil,
            createdAt: Date(),
            sortOrder: (folders.map(\.sortOrder).max() ?? -1) + 1,
            iconKind: iconKind,
            iconValue: iconValue,
            iconColorHex: iconColorHex)
        do { try archive.save(folder) }
        catch { PersistenceStatus.shared.report(error) }
        reload()
        return folder
    }

    func updateFolder(_ folder: MeetingFolder) {
        do { try archive.save(folder) }
        catch { PersistenceStatus.shared.report(error) }
        reload()
    }

    func deleteFolder(id: UUID, meetingRepository: MeetingRepository) {
        let members = meetingRepository.meetings.filter { $0.folderID == id }
        for meeting in members {
            var m = meeting
            m.folderID = nil
            meetingRepository.upsert(m)
        }
        guard !members.contains(where: { meeting in
            FilePersistence.failures.keys.contains(meetingRepository.archive.folder(for: meeting.id).appendingPathComponent("meeting.json"))
        }) else { return }
        do { try archive.deleteFolder(id: id) }
        catch { PersistenceStatus.shared.report(error); return }
        reload()
    }

    func assign(meetingID: UUID, to folderID: UUID?, meetingRepository: MeetingRepository) {
        guard var meeting = meetingRepository.meeting(id: meetingID) else { return }
        meeting.folderID = folderID
        meetingRepository.upsert(meeting)
        if let folderID {
            setRuleAndBackfill(for: meeting, folderID: folderID, meetingRepository: meetingRepository)
        }
    }

    func assign(calendarTitle: String, to folderID: UUID, meetingRepository: MeetingRepository) {
        let key = FolderTitleNormalizer.key(for: calendarTitle)
        guard !key.isEmpty else { return }
        do { try archive.setRule(normalizedTitle: key, folderID: folderID) }
        catch { PersistenceStatus.shared.report(error); return }
        reload()
        backfillUnfiled(forKey: key, folderID: folderID, meetingRepository: meetingRepository)
    }

    /// Legacy alias for views not yet on `MeetingRepository`.
    func deleteFolder(id: UUID, meetingStore: MeetingStore) {
        deleteFolder(id: id, meetingRepository: meetingStore)
    }

    func assign(meetingID: UUID, to folderID: UUID?, meetingStore: MeetingStore) {
        assign(meetingID: meetingID, to: folderID, meetingRepository: meetingStore)
    }

    func assign(calendarTitle: String, to folderID: UUID, meetingStore: MeetingStore) {
        assign(calendarTitle: calendarTitle, to: folderID, meetingRepository: meetingStore)
    }

    func folder(forTitle title: String) -> MeetingFolder? {
        guard let rule = archive.rule(forTitle: title) else { return nil }
        return folders.first { $0.id == rule.folderID }
    }

    func folder(id: UUID) -> MeetingFolder? {
        folders.first { $0.id == id }
    }

    func meetings(in folderID: UUID, from store: MeetingStore) -> [Meeting] {
        store.meetings
            .filter { $0.folderID == folderID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Private

    private func setRuleAndBackfill(
        for meeting: Meeting, folderID: UUID, meetingRepository: MeetingRepository
    ) {
        let raw = meeting.calendarEventTitle ?? meeting.title
        let key = FolderTitleNormalizer.key(for: raw)
        guard !key.isEmpty else { return }
        do { try archive.setRule(normalizedTitle: key, folderID: folderID) }
        catch { PersistenceStatus.shared.report(error); return }
        reload()
        backfillUnfiled(forKey: key, folderID: folderID, meetingRepository: meetingRepository)
    }

    private func backfillUnfiled(
        forKey key: String, folderID: UUID, meetingRepository: MeetingRepository
    ) {
        for meeting in meetingRepository.meetings where meeting.folderID == nil {
            let raw = meeting.calendarEventTitle ?? meeting.title
            guard FolderTitleNormalizer.key(for: raw) == key else { continue }
            var m = meeting
            m.folderID = folderID
            meetingRepository.upsert(m)
        }
    }
}
