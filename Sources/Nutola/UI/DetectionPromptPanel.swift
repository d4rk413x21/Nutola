import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating floating panel so the "Record this meeting?" card can appear on
/// its own (SwiftUI's MenuBarExtra popover can't be opened programmatically) without stealing
/// focus from whatever the user is doing. canBecomeKey stays true so the SwiftUI buttons inside
/// react to clicks; nonactivatingPanel keeps the app itself from coming forward.
private final class FloatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Persists and applies floating-panel placement. Auto-position only until the user drags.
@MainActor
private final class FloatingPanelPlacement {
  private let originXKey: String
  private let originYKey: String
  private var moveObserver: NSObjectProtocol?
  private(set) var userPlaced: Bool
  private var suppressMoveSaves = false
  var onUserMoved: ((NSWindow) -> Void)?

  init(originXKey: String, originYKey: String) {
    self.originXKey = originXKey
    self.originYKey = originYKey
    userPlaced = AppSettings.defaults.object(forKey: originXKey) != nil
  }

  func place(_ panel: NSWindow, defaultFrame: () -> NSRect) {
    let size = panel.frame.size
    if userPlaced, let origin = savedOrigin {
      panel.setFrameOrigin(clamped(origin, size: size))
    } else {
      panel.setFrame(defaultFrame(), display: false)
    }
  }

  func bindMoveNotifications(for panel: NSWindow) {
    guard moveObserver == nil else { return }
    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: panel, queue: .main
    ) { [weak self, weak panel] _ in
      Task { @MainActor in
        guard let self, let panel, !self.suppressMoveSaves else { return }
        self.save(panel.frame.origin)
        self.userPlaced = true
        self.onUserMoved?(panel)
      }
    }
  }

  /// Pins the pill's top-trailing corner in screen space while the panel resizes.
  func setFrameKeepingPillAnchor(_ panel: NSWindow, size: NSSize, pillAnchor: NSPoint) {
    suppressMoveSaves = true
    defer { suppressMoveSaves = false }
    let inset = RecordingPillLayout.inset
    let origin = clamped(
      NSPoint(
        x: pillAnchor.x + inset - size.width,
        y: pillAnchor.y + inset - size.height),
      size: size)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }

  /// Keeps the panel's top-trailing corner fixed so the pill handle stays put.
  func resizeKeepingTopRight(_ panel: NSWindow, size: NSSize) {
    suppressMoveSaves = true
    defer { suppressMoveSaves = false }
    let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
    let origin = clamped(
      NSPoint(x: topRight.x - size.width, y: topRight.y - size.height),
      size: size)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }

  func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
    clamped(origin, size: size)
  }

  private func save(_ origin: NSPoint) {
    AppSettings.defaults.set(origin.x, forKey: originXKey)
    AppSettings.defaults.set(origin.y, forKey: originYKey)
  }

  private var savedOrigin: NSPoint? {
    guard AppSettings.defaults.object(forKey: originXKey) != nil else { return nil }
    return NSPoint(
      x: AppSettings.defaults.double(forKey: originXKey),
      y: AppSettings.defaults.double(forKey: originYKey))
  }

  private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
    guard let screen = panelScreen(for: origin) ?? NSScreen.main else { return origin }
    let visible = screen.visibleFrame
    let x = min(max(origin.x, visible.minX), visible.maxX - size.width)
    let y = min(max(origin.y, visible.minY), visible.maxY - size.height)
    return NSPoint(x: x, y: y)
  }

  private func panelScreen(for origin: NSPoint) -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(origin, $0.frame, false) }
  }
}

/// Transparent click target that works on the first mouse-down in a non-activating panel.
private struct FirstMouseClickArea: NSViewRepresentable {
  var onClick: () -> Void

  func makeNSView(context: Context) -> ClickView {
    let view = ClickView()
    view.onClick = onClick
    return view
  }

  func updateNSView(_ nsView: ClickView, context: Context) {
    nsView.onClick = onClick
  }

  final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
  }
}

/// Drag handle that moves the hosting NSPanel without stealing button clicks elsewhere.
private struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> DragAreaView { DragAreaView() }
  func updateNSView(_ nsView: DragAreaView, context: Context) {}

  final class DragAreaView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
      window?.performDrag(with: event)
    }
  }
}

/// Pill handle: drag anywhere, click without moving toggles expand/collapse.
private struct PillHandleArea: NSViewRepresentable {
  var onClick: () -> Void

  func makeNSView(context: Context) -> PillHandleView {
    let view = PillHandleView()
    view.onClick = onClick
    return view
  }

  func updateNSView(_ nsView: PillHandleView, context: Context) {
    nsView.onClick = onClick
  }

  final class PillHandleView: NSView {
    var onClick: (() -> Void)?
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var dragged = false
    private let clickThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      dragged = false
      dragStartMouse = NSEvent.mouseLocation
      dragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
      guard let window else { return }
      let current = NSEvent.mouseLocation
      let delta = NSPoint(
        x: current.x - dragStartMouse.x,
        y: current.y - dragStartMouse.y)
      if hypot(delta.x, delta.y) >= clickThreshold { dragged = true }
      window.setFrameOrigin(
        NSPoint(
          x: dragStartOrigin.x + delta.x,
          y: dragStartOrigin.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
      if !dragged { onClick?() }
    }
  }
}

/// Shows/hides the floating detection prompt in lockstep with `AppState.detectedAppName`.
/// Owned by the AppDelegate for the app's lifetime.
@MainActor
final class DetectionPromptController {
  private var panel: FloatingPanel?
  private var shownName: String?
  private var isDismissing = false
  private var cancellable: AnyCancellable?

  init() {
    // detectedAppName is only ever non-nil while detection is on and auto-record is off, and
    // it clears on record/dismiss/mic-release — so binding the panel straight to it needs no
    // extra state. removeDuplicates avoids rebuilding the card on redundant re-publishes.
    cancellable = AppState.shared.$detectedAppName
      .removeDuplicates()
      .sink { [weak self] name in self?.update(appName: name) }
  }

  private func update(appName: String?) {
    guard let appName else {
      shownName = nil
      isDismissing = false
      panel?.orderOut(nil)
      return
    }
    guard !isDismissing else { return }
    let panel = ensurePanel()
    if appName != shownName {
      shownName = appName
      let host = NSHostingController(
        rootView: DetectionPromptView(
          appName: appName,
          onRecord: { Task { await AppState.shared.acceptDetection() } },
          onDismiss: { AppState.shared.dismissDetection() },
          onAutoDismiss: { [weak self] in self?.dismissAnimatedToRight() }
        )
        .nutolaAppearance())
      panel.contentViewController = host
      panel.setContentSize(host.view.fittingSize)
    }
    position(panel)
    panel.orderFrontRegardless()  // show without activating the app
  }

  private func dismissAnimatedToRight() {
    guard !isDismissing, let panel else {
      AppState.shared.dismissDetection()
      return
    }
    isDismissing = true
    let start = panel.frame
    var end = start
    end.origin.x = start.maxX + 24
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.28
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
      panel.animator().setFrame(end, display: true)
    } completionHandler: { [weak self] in
      Task { @MainActor in
        panel.alphaValue = 1
        panel.setFrame(start, display: false)
        self?.shownName = nil
        AppState.shared.dismissDetection()
      }
    }
  }

  private func ensurePanel() -> FloatingPanel {
    if let panel { return panel }
    let panel = FloatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    // Meeting apps are often full-screen; ride along over them and across every Space.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false  // the card draws its own rounded shadow
    self.panel = panel
    return panel
  }

  /// Top-right, just under the menu bar. The +8 nudges account for the card's transparent
  /// shadow padding so the visible card hugs the corner rather than floating off it.
  private func position(_ panel: FloatingPanel) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(
        x: visible.maxX - size.width + 8,
        y: visible.maxY - size.height + 8))
  }
}

/// Layout metrics for the recording pill — shared with panel placement so the handle
/// doesn't shift when the expanded card is shown or hidden.
private enum RecordingPillLayout {
  static let inset: CGFloat = 6
  static let cardInset: CGFloat = 8
  /// Visual space between the expanded card and the pill.
  static let gap: CGFloat = 2
  static let width: CGFloat = 44
  /// Stripes (19) + spacing (14) + indicator (16) + vertical padding (24).
  static let height: CGFloat = 73
  /// Matches `RecordingExpandedCardView` (300 + 12 padding each side).
  static let cardWidth: CGFloat = 324
  /// Header + transcript (190) + buttons + spacing + card padding.
  static let cardHeight: CGFloat = 286

  static var minimizedSize: NSSize {
    NSSize(width: gap + width + inset, height: inset + height + inset)
  }

  static var cardPanelSize: NSSize {
    NSSize(
      width: cardInset + cardWidth + gap,
      height: cardInset + cardHeight + cardInset)
  }

  static func cardOrigin(leftOf pillFrame: NSRect, cardSize: NSSize = cardPanelSize) -> NSPoint {
    NSPoint(x: pillFrame.minX - cardSize.width, y: pillFrame.maxY - cardSize.height)
  }

  static func pillFrame(anchor: NSPoint) -> NSRect {
    let size = minimizedSize
    return NSRect(
      x: anchor.x + inset - size.width,
      y: anchor.y + inset - size.height,
      width: size.width,
      height: size.height)
  }

  static func pillAnchor(in panelFrame: NSRect) -> NSPoint {
    NSPoint(x: panelFrame.maxX - inset, y: panelFrame.maxY - inset)
  }

  static func defaultPillAnchor(on screen: NSScreen) -> NSPoint {
    let visible = screen.visibleFrame
    return NSPoint(
      x: visible.maxX - 16 - inset,
      y: visible.midY + height / 2)
  }
}

/// Drag handle that moves the pill panel; the expanded card follows.
private struct CardDragArea: NSViewRepresentable {
  var pillPanel: NSWindow?
  var onMoved: () -> Void

  func makeNSView(context: Context) -> CardDragView {
    let view = CardDragView()
    view.pillPanel = pillPanel
    view.onMoved = onMoved
    return view
  }

  func updateNSView(_ nsView: CardDragView, context: Context) {
    nsView.pillPanel = pillPanel
    nsView.onMoved = onMoved
  }

  final class CardDragView: NSView {
    weak var pillPanel: NSWindow?
    var onMoved: (() -> Void)?
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero

    override func mouseDown(with event: NSEvent) {
      dragStartMouse = NSEvent.mouseLocation
      dragStartOrigin = pillPanel?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
      guard let pillPanel else { return }
      let current = NSEvent.mouseLocation
      pillPanel.setFrameOrigin(
        NSPoint(
          x: dragStartOrigin.x + current.x - dragStartMouse.x,
          y: dragStartOrigin.y + current.y - dragStartMouse.y))
      onMoved?()
    }
  }
}

/// Shows/hides separate pill + expanded-card panels in lockstep with `AppState.session`.
@MainActor
final class RecordingCardController {
  private var pillPanel: FloatingPanel?
  private var cardPanel: FloatingPanel?
  private var shownID: UUID?
  private var placedForSession = false
  private var cardVisible = false
  private var cancellable: AnyCancellable?
  private let placement = FloatingPanelPlacement(
    originXKey: SettingsKey.recordingCardOriginX,
    originYKey: SettingsKey.recordingCardOriginY)

  init() {
    placement.onUserMoved = { [weak self] _ in self?.syncCardPanel(animated: false) }
    cancellable = AppState.shared.$session
      .combineLatest(
        AppState.shared.$recordingCardDismissed,
        AppState.shared.$recordingCardMinimized,
        AppState.shared.$showLiveRecordingCard
      )
      .removeDuplicates {
        $0.0?.meetingID == $1.0?.meetingID
          && $0.1 == $1.1
          && $0.2 == $1.2
          && $0.3 == $1.3
      }
      .sink { [weak self] session, dismissed, minimized, showCard in
        self?.update(
          session: session,
          dismissed: dismissed,
          minimized: minimized,
          showCard: showCard)
      }
  }

  private func update(
    session: RecordingSession?,
    dismissed: Bool,
    minimized: Bool,
    showCard: Bool
  ) {
    guard let session else {
      shownID = nil
      placedForSession = false
      cardVisible = false
      hidePanels()
      return
    }
    guard showCard, !dismissed else {
      hidePanels(keepSession: true)
      return
    }

    let pill = ensurePillPanel()
    let card = ensureCardPanel()

    if session.meetingID != shownID {
      shownID = session.meetingID
      placedForSession = false
      cardVisible = false
      rebuildContent(session: session)
    }

    if !placedForSession {
      pill.setContentSize(RecordingPillLayout.minimizedSize)
      if placement.userPlaced {
        placement.place(pill) { pill.frame }
      } else {
        defaultPillPosition(pill)
      }
      placedForSession = true
    }

    let targetVisible = !minimized
    let animate = cardVisible != targetVisible && placedForSession
    setCardVisible(targetVisible, animated: animate)
    pill.orderFrontRegardless()
    if !minimized {
      card.orderFrontRegardless()
      pill.orderFrontRegardless()
    }
  }

  private func setCardVisible(_ visible: Bool, animated: Bool) {
    guard let card = cardPanel, pillPanel != nil else { return }
    guard visible != cardVisible else {
      if visible { syncCardPanel(animated: false) }
      return
    }
    cardVisible = visible

    if visible {
      syncCardPanel(animated: false)
      card.alphaValue = animated ? 0 : 1
      card.orderFrontRegardless()
      guard animated else { return }
      let target = card.frame
      var start = target
      start.origin.x += 16
      card.setFrame(start, display: false)
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.2
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card.animator().alphaValue = 1
        card.animator().setFrame(target, display: true)
      }
    } else {
      guard animated, card.isVisible else {
        card.orderOut(nil)
        card.alphaValue = 1
        return
      }
      let start = card.frame
      var end = start
      end.origin.x += 16
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        card.animator().alphaValue = 0
        card.animator().setFrame(end, display: true)
      } completionHandler: {
        card.orderOut(nil)
        card.alphaValue = 1
        card.setFrame(start, display: false)
      }
    }
  }

  private func syncCardPanel(animated: Bool) {
    guard let card = cardPanel, let pill = pillPanel else { return }
    let size = RecordingPillLayout.cardPanelSize
    let origin = placement.clampedOrigin(
      RecordingPillLayout.cardOrigin(leftOf: pill.frame, cardSize: size),
      size: size)
    let frame = NSRect(origin: origin, size: size)
    guard animated else {
      card.setFrame(frame, display: true)
      return
    }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      card.animator().setFrame(frame, display: true)
    }
  }

  private func hidePanels(keepSession: Bool = false) {
    cardPanel?.orderOut(nil)
    pillPanel?.orderOut(nil)
    if !keepSession {
      cardVisible = false
    }
  }

  private func rebuildContent(session: RecordingSession) {
    let app = AppState.shared
    let pillHost = NSHostingController(
      rootView: RecordingPillPanelView(
        session: session,
        minimized: Binding(
          get: { app.recordingCardMinimized },
          set: { app.recordingCardMinimized = $0 })
      )
      .nutolaAppearance())
    pillPanel?.contentViewController = pillHost
    pillPanel?.setContentSize(RecordingPillLayout.minimizedSize)

    let cardHost = NSHostingController(
      rootView: RecordingExpandedCardView(
        session: session,
        pillPanel: pillPanel,
        onMoved: { [weak self] in self?.syncCardPanel(animated: false) },
        onMinimize: { app.recordingCardMinimized = true },
        onAsk: { _ = AIAsk.openLive() },
        onStop: { Task { await app.stopRecording() } },
        localeStore: app.localeOverrides
      )
      .nutolaAppearance())
    cardPanel?.contentViewController = cardHost
    cardPanel?.setContentSize(RecordingPillLayout.cardPanelSize)
  }

  private func ensurePillPanel() -> FloatingPanel {
    if let pillPanel { return pillPanel }
    let panel = makePanel(size: RecordingPillLayout.minimizedSize)
    placement.bindMoveNotifications(for: panel)
    pillPanel = panel
    return panel
  }

  private func ensureCardPanel() -> FloatingPanel {
    if let cardPanel { return cardPanel }
    let panel = makePanel(size: RecordingPillLayout.cardPanelSize)
    cardPanel = panel
    return panel
  }

  private func makePanel(size: NSSize) -> FloatingPanel {
    let panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    return panel
  }

  private func defaultPillPosition(_ pill: FloatingPanel) {
    guard let screen = NSScreen.main else { return }
    let anchor = RecordingPillLayout.defaultPillAnchor(on: screen)
    pill.setFrame(RecordingPillLayout.pillFrame(anchor: anchor), display: false)
  }
}

private struct DetectionPromptView: View {
  let appName: String
  let onRecord: () -> Void
  let onDismiss: () -> Void
  let onAutoDismiss: () -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.nutolaActionColor) private var actionColor
  @State private var progress: CGFloat = 0
  @State private var closeHovered = false
  @State private var recordHovered = false

  private let cardWidth: CGFloat = 360
  private static let autoDismissSeconds: TimeInterval = 15

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      closeButton
      headerCard
    }
    .frame(width: cardWidth + 32)
    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 20, y: 8)
    .padding(20)  // transparent margin so the shadow isn't clipped by the panel bounds
    .task(id: appName) {
      progress = 0
      await Task.yield()
      withAnimation(.linear(duration: Self.autoDismissSeconds)) {
        progress = 1
      }
      try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
      guard !Task.isCancelled else { return }
      onAutoDismiss()
    }
  }

  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(closeHovered ? Theme.heading(scheme) : Theme.tertiary(scheme))
        .frame(width: 26, height: 26)
        .background(
          closeHovered ? Theme.card(scheme) : Theme.panel(scheme),
          in: Circle()
        )
        .overlay(Circle().strokeBorder(.primary.opacity(closeHovered ? 0.14 : 0.08)))
    }
    .buttonStyle(.plain)
    .onHover { closeHovered = $0 }
    .help("Dismiss")
    .accessibilityLabel("Dismiss")
  }

  private var headerCard: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Call detected")
          .font(.nutola(17, .semibold))
          .foregroundStyle(Theme.heading(scheme))
        Text(appName)
          .font(.nutola(12))
          .foregroundStyle(Theme.secondary(scheme))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WindowDragArea())
      takeNotesButton
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 15)
    .background(Theme.panel(scheme), in: shape)
    .overlay(shape.strokeBorder(.primary.opacity(0.09)))
    .overlay(alignment: .top) { progressBar }
    .clipShape(shape)
  }

  private var progressBar: some View {
    GeometryReader { geo in
      let fillWidth = geo.size.width * progress
      HStack(spacing: 0) {
        Rectangle()
          .fill(Theme.blueberry(scheme))
          .frame(width: fillWidth)
        Rectangle()
          .fill(Theme.blueberry(scheme).opacity(0.14))
      }
    }
    .frame(height: 2)
    .allowsHitTesting(false)
  }

  private var takeNotesButton: some View {
    takeNotesButtonLabel
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay { FirstMouseClickArea(onClick: onRecord) }
      .onHover { recordHovered = $0 }
      .help("Start recording")
      .accessibilityLabel("Start recording")
  }

  private var takeNotesButtonLabel: some View {
    HStack(spacing: 9) {
      NutolaStripes()
        .scaleEffect(0.38)
        .frame(width: 18, height: 24)
        .padding(3)
        .background(
          Color(red: 0.78, green: 0.91, blue: 0.35),
          in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      Text("Take notes")
        .font(.nutola(13, .semibold))
        .foregroundStyle(Theme.heading(scheme))
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .background(
      recordHovered ? Theme.surface(scheme) : Theme.card(scheme),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          recordHovered ? actionColor.opacity(0.35) : .primary.opacity(0.07),
          lineWidth: recordHovered ? 1.5 : 1))
  }
}

private struct RecordingPillPanelView: View {
  @ObservedObject var session: RecordingSession
  @Binding var minimized: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    pillHandle
      .padding(.top, RecordingPillLayout.inset)
      .padding(.trailing, RecordingPillLayout.inset)
      .padding(.bottom, RecordingPillLayout.inset)
      .padding(.leading, RecordingPillLayout.gap)
  }

  private var pillHandle: some View {
    VStack(spacing: 14) {
      NutolaStripes()
        .scaleEffect(0.32)
        .frame(width: 15, height: 19)
      Group {
        if minimized {
          MeterBars(levels: session.micBarLevels, barCount: 3)
        } else {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
        }
      }
      .frame(height: 16)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 8)
    .frame(width: RecordingPillLayout.width)
    .floatingSurface(in: Capsule())
    .overlay { PillHandleArea(onClick: { minimized.toggle() }) }
    .help(minimized ? "Expand live transcript" : "Minimize")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Live recording")
    .accessibilityValue(minimized ? "Collapsed" : "Expanded")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: Text("Expand or minimize transcript")) { minimized.toggle() }
    .focusable()
    .onKeyPress(.return) { minimized.toggle(); return .handled }
    .onKeyPress(.space) { minimized.toggle(); return .handled }
  }
}

private struct RecordingExpandedCardView: View {
  @ObservedObject var session: RecordingSession
  var pillPanel: NSWindow?
  var onMoved: () -> Void
  var onMinimize: () -> Void
  var onAsk: () -> Void
  var onStop: () -> Void
  var localeStore: TranscriptionLocaleStore?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.nutolaActionColor) private var actionColor

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        RecordDot()
        Text("Recording")
          .font(.nutola(14, .semibold))
        Spacer(minLength: 0)
        localeMenu
        Text(timeString(session.elapsed))
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
        Button(action: onMinimize) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Minimize")
        .accessibilityLabel("Minimize")
      }
      .background(CardDragArea(pillPanel: pillPanel, onMoved: onMoved))
      if let notice = session.speakerTrackingNotice {
        Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      transcript
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          Button(action: onAsk) {
            Label("Ask AI live", systemImage: "sparkles")
              .font(.nutola(12, .semibold))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 2)
          }
          .buttonStyle(.glassProminent)
          .tint(actionColor)
          Button("Stop", action: onStop)
            .font(.nutola(12))
            .buttonStyle(.glass)
        }
      }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .floatingSurface(in: RoundedRectangle(cornerRadius: 16), opaque: true)
    .padding(.top, RecordingPillLayout.cardInset)
    .padding(.leading, RecordingPillLayout.cardInset)
    .padding(.bottom, RecordingPillLayout.cardInset)
    .padding(.trailing, RecordingPillLayout.gap)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if session.liveSegments.isEmpty, session.volatileText.isEmpty {
            Text("Listening…")
              .font(.nutola(12))
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(LiveTranscriber.turns(from: session.liveSegments)) { turn in
            VStack(alignment: .leading, spacing: 2) {
              Text(liveSpeakerName(for: turn.speakerID))
                .font(.nutola(10, .bold))
                .foregroundStyle(
                  turn.speakerID == LiveTranscriber.youSpeakerID
                    ? Theme.blueberry : Theme.raspberry)
              Text(turn.text)
                .font(.nutola(12))
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          if !session.volatileText.isEmpty {
            Text(session.volatileText)
              .font(.nutola(12))
              .italic()
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Color.clear.frame(height: 1).id("card-bottom")
        }
        .padding(10)
      }
      .frame(height: 190)
      .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 8))
      // Jump to the bottom once when the card appears so the latest
      // turn is in view, but don't force-scroll afterwards — the user
      // can scroll up to read earlier turns without being yanked back.
      .onAppear { proxy.scrollTo("card-bottom", anchor: .bottom) }
    }
  }

  private func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  @ViewBuilder
  private var localeMenu: some View {
    guard let store = localeStore else { return AnyView(EmptyView()) }
    let current = store.identifier(forMeetingID: session.meetingID.uuidString)
    let label = current.map { Self.shortLanguageLabel(for: $0) } ?? "Auto"
    return AnyView(
      Menu {
        Button {
          session.setTranscriptionLocale(nil, store: store)
        } label: {
          if current == nil { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
        }
        Divider()
        ForEach(Self.pickerLocales(), id: \.0) { entry in
          Button {
            session.setTranscriptionLocale(entry.locale, store: store)
          } label: {
            if current == entry.id {
              Label(Self.languageLabel(for: entry.locale), systemImage: "checkmark")
            } else {
              Text(Self.languageLabel(for: entry.locale))
            }
          }
        }
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "globe")
          Text(label)
        }
        .font(.nutola(11, .medium))
        .foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Transcription language — pin to one locale or use Auto")
    )
  }

  private func liveSpeakerName(for speakerID: String) -> String {
    if speakerID == LiveTranscriber.othersSpeakerID,
      let active = session.activeRemoteSpeaker
    {
      return active
    }
    return LiveTranscriber.name(for: speakerID)
  }

  /// Locales shown in the picker, ordered: current system locale first (if
  private static func pickerLocales() -> [(id: String, locale: Locale)] {
    var seen = Set<String>()
    var out: [(id: String, locale: Locale)] = []
    let currentID = Locale.current.identifier(.bcp47)
    let cur = Locale(identifier: currentID)
    if seen.insert(cur.identifier(.bcp47)).inserted {
      out.append((id: cur.identifier(.bcp47), locale: cur))
    }
    for locale in TranscriptionLocales.presetLocales {
      if seen.insert(locale.identifier(.bcp47)).inserted {
        out.append((id: locale.identifier(.bcp47), locale: locale))
      }
    }
    return out
  }
  private static func languageLabel(for locale: Locale) -> String {
    let id = locale.identifier(.bcp47)
    let name = locale.localizedString(forIdentifier: id) ?? id
    return name
  }

  private static func shortLanguageLabel(for identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    return locale.localizedString(forIdentifier: identifier) ?? identifier
  }
}
