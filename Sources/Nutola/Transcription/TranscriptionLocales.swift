import Foundation
import Speech

/// Resolves and prepares on-device speech models for meeting transcription.
///
/// Meetings often mix English and Brazilian Portuguese. Apple's SpeechTranscriber
/// can adapt mid-stream when multiple locale assets are reserved, but only if those
/// models are installed — using `Locale.current` alone (typically en-US) locks
/// Portuguese speech into English phonetics.
enum TranscriptionLocales {
  static let italian = Locale(identifier: "it-IT")
  static let english = Locale(identifier: "en-US")
  static let brazilianPortuguese = Locale(identifier: "pt-BR")

  /// A curated set of common locales offered in the language picker, in the
  /// order they should appear. The picker also appends any other installed
  /// speech locales not in this preset so users see everything available.
  static let presetLocales: [Locale] = [
    Locale(identifier: "en-US"),
    Locale(identifier: "pt-BR"),
    Locale(identifier: "en-GB"),
    Locale(identifier: "es-ES"),
    Locale(identifier: "es-MX"),
    Locale(identifier: "fr-FR"),
    Locale(identifier: "de-DE"),
    Locale(identifier: "it-IT"),
    Locale(identifier: "ja-JP"),
    Locale(identifier: "ko-KR"),
    Locale(identifier: "zh-CN"),
    Locale(identifier: "zh-TW"),
    Locale(identifier: "hi-IN"),
    Locale(identifier: "ru-RU"),
    Locale(identifier: "nl-NL"),
    Locale(identifier: "pl-PL"),
    Locale(identifier: "tr-TR"),
    Locale(identifier: "ar-SA"),
  ]
  /// Italian-first default for this fork, independent of the macOS UI locale.
  /// Explicit per-meeting selections take precedence in both live and batch modes.
  static func primaryCandidateIdentifiers() -> [String] {
    dedupe([
      italian.identifier(.bcp47),
      Locale.current.identifier(.bcp47),
      english.identifier(.bcp47),
      brazilianPortuguese.identifier(.bcp47),
    ])
  }

  /// Every supported locale whose assets should be reserved for code-switching.
  static func assetCandidateIdentifiers() -> [String] {
    dedupe([
      italian.identifier(.bcp47),
      Locale.current.identifier(.bcp47),
      english.identifier(.bcp47),
      brazilianPortuguese.identifier(.bcp47),
    ])
  }

  static func supportedCandidates() async -> [Locale] {
    var out: [Locale] = []
    var seen = Set<String>()
    for raw in assetCandidateIdentifiers() {
      guard
        let resolved = await SpeechTranscriber.supportedLocale(
          equivalentTo: Locale(identifier: raw)),
        seen.insert(resolved.identifier(.bcp47)).inserted
      else { continue }
      out.append(resolved)
    }
    return out
  }

  static func primary() async -> Locale? {
    for raw in primaryCandidateIdentifiers() {
      if let resolved = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: raw))
      {
        NutolaConsoleLog.locales("primary locale → \(resolved.identifier(.bcp47))")
        return resolved
      }
    }
    let fallback = (await supportedCandidates()).first
    if let fallback {
      NutolaConsoleLog.locales("primary fallback → \(fallback.identifier(.bcp47))")
    } else {
      NutolaConsoleLog.locales("no supported locale found")
    }
    return fallback
  }

  static func modelsInstalled() async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    let required = await supportedCandidates()
    guard !required.isEmpty else { return false }
    let installed = Set((await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) })
    return required.allSatisfy { installed.contains($0.identifier(.bcp47)) }
  }

  /// Reserves English + Brazilian Portuguese (and the current locale when distinct)
  /// and downloads any missing on-device assets.
  static func ensureModels(progress: (@Sendable (Double) -> Void)? = nil) async throws {
    guard SpeechTranscriber.isAvailable else { throw TranscriberError.modelUnavailable }
    guard let primary = await primary() else { throw TranscriberError.modelUnavailable }

    let locales = await supportedCandidates()
    guard !locales.isEmpty else { throw TranscriberError.modelUnavailable }

    for locale in locales {
      try await AssetInventory.reserve(locale: locale)
    }

    let installed = Set((await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) })
    let missing = locales.filter { !installed.contains($0.identifier(.bcp47)) }
    let toFetch = missing.isEmpty ? [primary] : missing
    if !missing.isEmpty {
      NutolaConsoleLog.locales(
        "downloading models: \(missing.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
    } else {
      NutolaConsoleLog.locales("all speech models installed")
    }

    var observation: NSKeyValueObservation?
    defer { observation?.invalidate() }

    for (index, locale) in toFetch.enumerated() {
      let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
      guard
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
      else {
        if index == toFetch.count - 1 { progress?(1) }
        continue
      }
      if let progress {
        observation = request.progress.observe(
          \Progress.fractionCompleted, options: [.initial, .new]
        ) { progressValue, _ in
          let slice = 1.0 / Double(toFetch.count)
          progress((Double(index) + progressValue.fractionCompleted) * slice)
        }
      }
      try await request.downloadAndInstall()
    }
    progress?(1)
  }

  /// Read the per-meeting UI language pin from the same archive used by
  /// TranscriptionLocaleStore. Post-recording processing may execute outside
  /// the main actor, so it reads the persisted value rather than the UI store.
  static func storedLocale(forMeetingID meetingID: UUID, root: URL) -> Locale? {
    let file = root.appendingPathComponent("TranscriptionLocales/overrides.json")
    guard let data = try? Data(contentsOf: file),
          let overrides = try? JSONDecoder().decode([String: String].self, from: data),
          let identifier = overrides[meetingID.uuidString],
          !identifier.isEmpty
    else { return nil }
    return Locale(identifier: identifier)
  }

  private static func dedupe(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }
}
