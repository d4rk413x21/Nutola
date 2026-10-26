import Foundation
import SwiftUI

/// Per-meeting transcription language. Maps a `Meeting.id` (UUID) to a BCP-47
/// locale identifier (e.g. "en-US", "pt-BR"). A nil value means "auto" —
/// `TranscriptionLocales.primary()` adapts mid-stream. When set, the
/// `LiveTranscriber` locks its channels to that locale for the whole meeting.
///
/// The override is sticky until the meeting ends, matching the user's mental
/// model of picking a language at the start of a call. Resuming an in-flight
/// meeting re-reads the override so the choice survives a restart.
@MainActor
final class TranscriptionLocaleStore: ObservableObject {
  @Published private(set) var overrides: [String: String] = [:]

  private let file: URL

  init(root: URL = MeetingArchive.defaultRoot) {
    let dir = root.appendingPathComponent("TranscriptionLocales", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    file = dir.appendingPathComponent("overrides.json")
    load()
  }

  /// Returns the BCP-47 identifier assigned to `meetingID`, or nil for auto.
  func identifier(forMeetingID meetingID: String) -> String? {
    overrides[meetingID]
  }

  /// Returns the `Locale` assigned to `meetingID`, or nil for auto.
  func locale(forMeetingID meetingID: String) -> Locale? {
    guard let id = overrides[meetingID] else { return nil }
    return Locale(identifier: id)
  }

  /// Assign a locale identifier (BCP-47) to `meetingID`. Passing nil clears
  /// the override and reverts to auto.
  func set(meetingID: String, localeIdentifier: String?) {
    let trimmed = localeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (trimmed?.isEmpty == false) ? trimmed : nil
    if overrides[meetingID] == value { return }
    overrides[meetingID] = value
    persist()
  }

  func clear(meetingID: String) {
    guard overrides[meetingID] != nil else { return }
    overrides[meetingID] = nil
    persist()
  }

  /// Prune entries whose locale isn't supported by SpeechTranscriber on this
  /// device, so a stale hand-edited file doesn't lock a meeting to a locale
  /// with no installed model.
  func pruneUnsupported(_ supported: [Locale]) {
    let valid = Set(supported.map { $0.identifier(.bcp47) })
    let stale = overrides.filter { !valid.contains($0.value) }
    guard !stale.isEmpty else { return }
    for meetingID in stale.keys { overrides[meetingID] = nil }
    persist()
  }

  private func load() {
    guard let data = try? Data(contentsOf: file),
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    else { return }
    overrides = decoded
  }

  private func persist() {
    do {
        let data = try JSONEncoder().encode(overrides)
        try FilePersistence.write(data, to: file)
    } catch { PersistenceStatus.record(error) }
  }
}
