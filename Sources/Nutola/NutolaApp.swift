import AppKit
import CoreServices
import SwiftUI

struct NutolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppState.shared
    // Captured once at launch (not re-read live) so .defaultLaunchBehavior below
    // is a stable, one-time decision — see Window("onboarding") for why.
    private let showOnboardingAtLaunch = !AppSettings.didCompleteOnboarding
    private let openMainAtLaunch = AppSettings.didCompleteOnboarding && AppSettings.openMainWindowAtLaunch

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .nutolaAppearance()
        } label: {
            MenuBarLabel(
                detecting: app.detectedAppName != nil,
                isRecording: app.isRecording,
                recordingElapsed: app.session?.menuBarElapsed ?? 0,
                nextEvent: menuBarNextEvent)
        }
        .menuBarExtraStyle(.window)
        Window("Nutola", id: "main") {
            MainWindowView()
                .environmentObject(app)
                .nutolaAppearance()
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(openMainAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Nutola") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Meeting notes and development tasks.\n\(AppIdentity.repositoryURL.absoluteString)",
                            attributes: [.font: NSFont.systemFont(ofSize: 11)])
                    ])
                }
            }
        }

        Window("Welcome to Nutola", id: "onboarding") {
            OnboardingView()
                .environmentObject(app)
                .nutolaAppearance()
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showOnboardingAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environmentObject(app)
                .nutolaAppearance()
        }
    }

    private var menuBarNextEvent: MenuBarUpcomingEvent? {
        guard !app.isRecording, app.detectedAppName == nil,
              AppSettings.useCalendar, AppSettings.showUpcomingInMenuBar, CalendarAuthorization.isAuthorized,
              let event = app.calendar.nextUpcomingEvent,
              let countdown = app.calendar.countdownText(for: event) else { return nil }
        return MenuBarUpcomingEvent(title: event.title, countdown: countdown)
    }
}

struct MenuBarUpcomingEvent: Equatable {
    var title: String
    var countdown: String
}

@MainActor
enum MenuBarTitleTruncator {
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: 11) ?? base
    }()
    private static let separator = "•"
    private static let ellipsis = ".."
    private static let spacing: CGFloat = 4
    /// Total width budget for title + separator + countdown in the menu-bar slot.
    private static let textBudget: CGFloat = 148

    /// Cached `label(for:)` output keyed by the event. The menu-bar label view
    /// re-renders on every state change, but the upcoming event (title +
    /// countdown) is usually unchanged between renders — memoizing avoids the
    /// `boundingRect`/`size` width measurements on every redraw. Bounded to one
    /// entry: only the most recent event is kept, which is what the menu bar
    /// repeatedly asks for. `MenuBarUpcomingEvent` is `Equatable` so the key
    /// comparison is exact.
    private static var cachedEvent: MenuBarUpcomingEvent?
    private static var cachedLabel: String?

    static func label(for event: MenuBarUpcomingEvent) -> String {
        if let cached = cachedLabel, cachedEvent == event {
            return cached
        }
        let suffix = separator + event.countdown
        let titleBudget = max(textBudget - width(of: suffix) - spacing, 36)
        let title = truncate(event.title, maxWidth: titleBudget)
        let result = title + suffix
        cachedEvent = event
        cachedLabel = result
        return result
    }

    private static func truncate(_ title: String, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let full = title as NSString
        let fullWidth = width(of: title)
        guard fullWidth > maxWidth else { return title }

        let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attrs).width
        let budget = max(maxWidth - ellipsisWidth, 0)
        guard budget > 0 else { return ellipsis }

        // Estimate the longest fitting prefix proportionally from the full width,
        // then correct by ±1 with a couple of measurements — one or two
        // `boundingRect`/`size` calls instead of the old ~log2(n) substring
        // probes, each of which allocated a fresh NSString. The estimate is
        // bounded below by 0 and above by the title length, and the correction
        // step guarantees we never overflow the budget.
        let fraction = budget / fullWidth
        var estimate = Int(CGFloat(full.length) * fraction)
        estimate = max(0, min(estimate, full.length))
        // Grow/shrink by one grapheme until we're at the widest prefix that fits.
        while estimate + 1 <= full.length,
              width(of: full.substring(to: estimate + 1)) <= budget {
            estimate += 1
        }
        while estimate > 0, width(of: full.substring(to: estimate)) > budget {
            estimate -= 1
        }
        return full.substring(to: estimate) + ellipsis
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []
    private var detectionPrompt: DetectionPromptController?
    private var recordingCard: RecordingCardController?
    private var recordingShortcutMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerApplicationIconWithLaunchServices()
        Task { @MainActor in AppState.shared.bootstrap() }
        observeWindowsForMenuBar()
        installRecordingShortcutMonitor()
        // The floating "Record this meeting?" card on detection, and the live
        // recording card (transcript + Ask Claude live) while recording.
        MainActor.assumeIsolated {
            detectionPrompt = DetectionPromptController()
            recordingCard = RecordingCardController()
        }
    }

    /// Global ⌃⌥R (Control+Option+R) toggle for recording — works regardless of
    /// which window is key (or none, since Nutola is an accessory app most of the time).
    private func installRecordingShortcutMonitor() {
        recordingShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains([.control, .option]),
                  event.keyCode == 15  // R
            else { return }
            MainActor.assumeIsolated {
                let app = AppState.shared
                if app.isRecording {
                    Task { await app.stopRecording() }
                } else {
                    Task { await app.startRecording() }
                }
            }
        }
    }

    /// Re-register the bundle so Notification Center picks up AppIcon.icns changes
    /// after rebuilds (LSUIElement apps cache the old glyph aggressively).
    private func registerApplicationIconWithLaunchServices() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    }

    /// .accessory apps (LSUIElement) have no Dock icon *and no menu bar at all* —
    /// promote to .regular only while a real Nutola window (main/Settings, not the
    /// MenuBarExtra popover panel) is open, so "Nutola" shows top-left like a normal
    /// app; drop back to accessory the moment the last real window closes.
    private func observeWindowsForMenuBar() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, Self.isRealAppWindow(window) else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, Self.isRealAppWindow(closing) else { return }
            // isMiniaturized too: a minimized real window is still open, just not visible.
            let stillOpen = NSApp.windows.contains {
                $0 !== closing && ($0.isVisible || $0.isMiniaturized) && Self.isRealAppWindow($0)
            }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        })
    }

    /// Excludes the MenuBarExtra(.window)'s own backing window (an untitled,
    /// nonactivating NSPanel) — only "real" titled windows (main/Settings/onboarding) qualify.
    private static func isRealAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    /// Finalize in-flight audio files before quitting — an unclosed AAC file has
    /// no moov atom and would be unreadable on the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            AppState.shared.prepareForTermination()
        }
        return .terminateNow
    }
}

struct MenuBarLabel: View {
    /// A meeting-ish app grabbed the mic and we're waiting on the user to hit Record.
    /// Swap in an attention glyph so the prompt is visible in the menu bar even if the
    /// notification was missed, quieted, or denied outright.
    var detecting: Bool = false
    /// Recording is in progress — show a live elapsed-time badge (mm:ss) next to the
    /// glyph so the user can tell at a glance that capture is running.
    var isRecording: Bool = false
    var recordingElapsed: TimeInterval = 0
    var nextEvent: MenuBarUpcomingEvent?

    var body: some View {
        if isRecording {
            recordingLabel
        } else if detecting {
            Image(systemName: "waveform.badge.exclamationmark")
        } else if let nextEvent {
            upcomingEventLabel(nextEvent)
        } else if let icon = Self.templateIcon {
            Image(nsImage: icon)
        } else {
            Image(systemName: "cup.and.saucer.fill")
        }
    }

    private var recordingLabel: some View {
        HStack(spacing: 4) {
            if let icon = Self.templateIcon {
                Image(nsImage: icon)
            }
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
            Text(recordingElapsedString)
                .font(.nutola(11, .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
        .help("Recording in progress")
    }

    private var recordingElapsedString: String {
        let s = Int(recordingElapsed)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func upcomingEventLabel(_ event: MenuBarUpcomingEvent) -> some View {
        HStack(spacing: 4) {
            if let icon = Self.templateIcon {
                Image(nsImage: icon)
            }
            Text(MenuBarTitleTruncator.label(for: event))
                .font(.nutola(11, .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .help(event.title)
    }

    static let templateIcon: NSImage? = {
        // Resolve the SPM resource bundle defensively. The generated `Bundle.module`
        // accessor only checks `Bundle.main.bundleURL` (the .app root) and a stale
        // build-time path, but `make app` ships the bundle under `Contents/Resources/`
        // (the canonical macOS location, exposed as `Bundle.main.resourceURL`). If
        // neither of the accessor's paths resolves — e.g. after a project rename or a
        // hand-assembled .app — it `fatalError`s at first menu-bar render and the app
        // can never relaunch. Look there ourselves before touching `Bundle.module`.
        let bundle: Bundle = {
            let name = "Nutola_Nutola"
            if let resourceURL = Bundle.main.resourceURL,
               let b = Bundle(url: resourceURL.appendingPathComponent("\(name).bundle"))
            { return b }
            return Bundle.module
        }()
        // Bundle image lookup pairs the @2x representation; NSImage(contentsOf:)
        // would load only the 1x bitmap and render blurry on Retina.
        guard let image = bundle.image(forResource: "NavIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
