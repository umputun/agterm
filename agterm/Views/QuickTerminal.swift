import agtermCore
import AppKit
import SwiftUI

/// The quick terminal: one scratch terminal per app, hosted in a detached floating panel on whichever screen
/// has focus rather than inside a window. A toolbar button, ⌃`, the control socket and the global hotkey all
/// summon the same panel; losing key hides it, which is what makes it a summon-and-dismiss surface rather
/// than window chrome. Hiding keeps the shell alive, since the surface is owned here rather than by the
/// panel's content view, so it survives the view being removed. Not persisted (fresh each launch).
///
/// App-level, not per-window: the panel belongs to no window, so `AGTERM_WINDOW_ID` is absent from its
/// environment and the surface carries only enabled + socket. `canShow` is what keeps it from outliving the
/// last window, agterm terminating on an empty open set (see `AppDelegate.applicationShouldTerminate…`).
@MainActor @Observable
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    /// Whether the panel is on screen. Observed, so the deck's gates and the control read-back follow it.
    private(set) var isVisible = false

    /// Whether the panel currently owns the keyboard. Distinct from `isVisible`, and it is this — not mere
    /// visibility — that every deck gate and focus guard reads: a PINNED panel (a control `quick show`) stays
    /// on screen after agterm loses key, and treating that as "a cover owns focus" would revoke first
    /// responder in every window and leave the user unable to type outside the panel's own frame.
    private(set) var holdsKey = false

    /// Whether the panel fills its screen instead of taking the inset 90% frame — the re-homed
    /// `surface.zoom --target quick`, which used to be a per-window `TerminalZoomTarget`. Cleared on hide,
    /// so a dismissed panel never reports a stale zoom.
    private(set) var isZoomed = false

    /// The long-lived quick-terminal surface, created lazily on first show and kept across hide/show so the
    /// shell survives. The panel's content pulls it imperatively, like a session owns its surface; nothing in
    /// SwiftUI observes the view itself.
    @ObservationIgnored private var surfaceView: GhosttySurfaceView?

    @ObservationIgnored private var panel: QuickTerminalPanel?

    /// The panel's content host, retained so a show can re-read the terminal color into it without
    /// rebuilding the panel (which would remount the surface).
    @ObservationIgnored private var hostingView: NSHostingView<QuickTerminalPanelContent>?

    /// Whether losing key dismisses the panel. A HUMAN summon (hotkey, ⌃`, toolbar, Dock) is
    /// dismiss-on-blur, which is what makes it summon-and-return. A control-driven show pins it instead:
    /// `show` activates agterm, so a script's very next command runs while some other application is coming
    /// back to the front, and a blur-dismissing panel would be gone before `quick type` or
    /// `surface zoom --target quick` could reach it.
    @ObservationIgnored private var dismissesOnFocusLoss = true

    /// The directory a freshly-created quick terminal spawns its shell in. Read once, at surface creation,
    /// so the quick terminal keeps its own working directory afterwards.
    @ObservationIgnored var cwdProvider: () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }

    /// The `AGTERM_*` environment a freshly-created quick terminal exposes to its shell (ENABLED + SOCKET —
    /// scratch and window-less, so no window/workspace/session ids). Read once, at surface creation.
    @ObservationIgnored var envProvider: () -> [String: String] = { [:] }

    /// Notes a keystroke as user activity on the active window's `AppStore`, so typing here resets that
    /// window's auto-follow idle timer (an idle fire must NOT change a selection while the user types).
    /// The controller is store-less, so the app supplies this; `surface()` forwards it to the surface's
    /// `onUserInput`, as the overlay/scratch factories do, and `handleShellExit` nils it on teardown.
    @ObservationIgnored var onUserInput: (() -> Void)?

    /// Whether this cover may claim keyboard focus. The app disables it while a control picker is up,
    /// stopping an in-flight show retry from stealing the picker's field.
    @ObservationIgnored var focusAllowed: () -> Bool = { true }

    /// Whether a show may proceed at all — false with no open window, where a panel would be the only thing
    /// on screen for an app that is about to terminate, and false while a control picker is pending, which
    /// owns the keyboard. The pick term is here rather than on each caller because the global hotkey reaches
    /// the controller directly, with none of the `uiActionsEnabled` gating every in-app path has.
    @ObservationIgnored var canShow: () -> Bool = { true }

    /// The opaque backing the panel paints behind the surface, which draws transparent under
    /// `background-opacity = 0`. Re-read on every show, so a theme change lands on the next summon.
    @ObservationIgnored var terminalColorProvider: () -> Color = { .black }

    /// When a resign-driven hide last fired, and how long a show is suppressed afterwards. AppKit makes the
    /// clicked window key BEFORE delivering the button action, so a click on the Quick Terminal toolbar
    /// button or Dock item first blurs the panel — and without this the toggle would then see
    /// `isVisible == false` and re-show the panel that same click just dismissed.
    @ObservationIgnored private var autoHiddenAt: Date?
    private static let reshowSuppression: TimeInterval = 0.3

    private init() {}

    /// Toolbar-button / hotkey / menu action: show if hidden, hide if visible. Always the human path, so the
    /// panel it shows dismisses on blur.
    ///
    /// `fromGlobalHotkey` bypasses the re-show suppression. That window exists because a CLICK on the
    /// toolbar button blurs the panel before its action arrives, and a keypress from another application
    /// causes no such blur — so suppressing it there would swallow a deliberate summon made within 300ms of
    /// the user clicking away.
    func toggle(fromGlobalHotkey: Bool = false) {
        if isVisible {
            hide()
            return
        }
        if !fromGlobalHotkey, let autoHiddenAt, Date().timeIntervalSince(autoHiddenAt) < Self.reshowSuppression {
            self.autoHiddenAt = nil
            return
        }
        show()
    }

    /// Show the panel. `dismissOnFocusLoss` false is the control path — see the property of that name.
    /// Idempotent, and deliberately still applies the pin when the panel is ALREADY up: a script running
    /// `quick show` over a panel the user summoned by hotkey is promised a panel that survives its next
    /// command, and returning early would leave that promise to a blur.
    func show(dismissOnFocusLoss: Bool = true) {
        guard canShow() else { return }
        // a control show over a user-summoned panel still pins it: the caller is a script either way.
        dismissesOnFocusLoss = dismissesOnFocusLoss && dismissOnFocusLoss
        autoHiddenAt = nil
        guard !isVisible else { return }
        isVisible = true
        let panel = ensurePanel()
        hostingView?.rootView = QuickTerminalPanelContent(controller: self,
                                                          terminalColor: terminalColorProvider())
        panel.setFrame(Self.targetFrame(zoomed: isZoomed), display: true)
        // NEVER `NSApp.activate()` here. Activating agterm raises ITS WINDOWS too, so summoning the panel
        // from another application buries that application behind the whole terminal, and dismissing leaves
        // the user in agterm instead of where they were. That round trip is the entire point of the feature.
        // `.nonactivatingPanel` exists for exactly this: the panel takes keyboard input while agterm stays
        // inactive, so hiding it returns the keyboard to whatever was in front, with nothing to restore.
        panel.orderFrontRegardless()
        panel.makeKey()
        focus()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        isZoomed = false
        holdsKey = false
        dismissesOnFocusLoss = true
        panel?.orderOut(nil)
    }

    /// The panel lost key. `holdsKey` drops either way — a PINNED panel stays on screen without owning the
    /// keyboard, and that is exactly the state the deck gates must not read as a cover. Only a human-summoned
    /// panel dismisses itself.
    private func handleResignKey() {
        holdsKey = false
        guard dismissesOnFocusLoss, isVisible else { return }
        hide()
        autoHiddenAt = Date()
    }

    /// Apply `surface.zoom --target quick`. Returns false when the panel is not up, which is what makes the
    /// control command answer `surface not available` rather than silently arming a zoom nothing renders.
    @discardableResult
    func setZoom(_ mode: ControlToggleMode) -> Bool {
        guard isVisible else { return false }
        let want = mode.desiredValue(current: isZoomed)
        guard want != isZoomed else { return true }
        isZoomed = want
        panel?.setFrame(Self.targetFrame(zoomed: want), display: true)
        focus()
        return true
    }

    /// The existing quick-terminal surface, or nil — does NOT create one (unlike `surface()`), so a settings
    /// broadcast can reach it without spawning a shell.
    func currentSurface() -> GhosttySurfaceView? { surfaceView }

    /// The surface to render in the panel, created on first use in the active cwd and reused afterwards.
    /// Recreated after the shell exits.
    func surface() -> GhosttySurfaceView {
        if let surfaceView { return surfaceView }
        let view = GhosttySurfaceView(workingDirectory: cwdProvider(), env: envProvider())
        view.onExit = { [weak self] in self?.handleShellExit() }
        view.onUserInput = onUserInput
        surfaceView = view
        return view
    }

    /// Re-assert first responder on the surface for a short window so focus lands once the panel is
    /// on-screen (a one-shot would race the panel's layout).
    func focus(attempt: Int = 0) {
        guard focusAllowed() else { return }
        if let surfaceView, let window = surfaceView.window {
            window.makeFirstResponder(surfaceView)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focus(attempt: attempt + 1)
        }
    }

    private func ensurePanel() -> QuickTerminalPanel {
        if let panel { return panel }
        let panel = QuickTerminalPanel(onBecomeKey: { [weak self] in self?.holdsKey = true },
                                       onResignKey: { [weak self] in self?.handleResignKey() })
        let host = NSHostingView(rootView: QuickTerminalPanelContent(
            controller: self, terminalColor: terminalColorProvider()
        ))
        panel.contentView = host
        hostingView = host
        self.panel = panel
        return panel
    }

    /// The quick-terminal shell exited: drop the panel with the surface it hosted so the next show spawns a
    /// fresh shell (the surface, not the panel, owns the shell).
    private func handleShellExit() {
        isVisible = false
        isZoomed = false
        // the next summon is a fresh panel and a fresh shell, so it starts from the default policy — a pin
        // left standing here would silently outlive the control show that set it.
        dismissesOnFocusLoss = true
        autoHiddenAt = nil
        holdsKey = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
        surfaceView?.onUserInput = nil
        surfaceView?.teardown()
        surfaceView = nil
    }

    /// The panel's comfortable maximum. The in-window overlay took 90% of its host and needed no cap, a
    /// window already being a modest size; 90% of a large display is not a quick aside but a wall of
    /// terminal, so the share is a floor-to-ceiling that stops growing past a readable width.
    private static let maxNormalSize = NSSize(width: 1100, height: 700)

    /// Centered on the focused screen at 90% of it or `maxNormalSize`, whichever is smaller, and its whole
    /// visible frame while zoomed. The panel follows the POINTER's screen, not the app's: it is summoned
    /// from another application, where agterm's own key window is no guide to where the user is looking.
    private static func targetFrame(zoomed: Bool) -> NSRect {
        let visible = activeScreen().visibleFrame
        guard !zoomed else { return visible }
        let size = NSSize(width: min(visible.width * 0.9, maxNormalSize.width),
                          height: min(visible.height * 0.9, maxNormalSize.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let under = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return under }
        return NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// The floating host. Borderless and non-activating so summoning it from another app is one deliberate
/// `NSApp.activate`, and joining all spaces so it lands on whichever Space the user is on instead of pulling
/// them back to agterm's. `canBecomeKey` is overridden because a borderless panel refuses key by default,
/// which would leave the terminal unable to take a keystroke.
@MainActor
final class QuickTerminalPanel: NSPanel {
    private let onBecomeKey: () -> Void
    private let onResignKey: () -> Void

    init(onBecomeKey: @escaping () -> Void, onResignKey: @escaping () -> Void) {
        self.onBecomeKey = onBecomeKey
        self.onResignKey = onResignKey
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // above every application's normal windows, since it is summoned over whatever the user is in.
        level = .floating
        // a panel defaults to hiding when its app deactivates, and agterm is deliberately never activated
        // for this, so the default would pull the panel away the moment it appeared.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // the panel is transient chrome, never part of the saved window set AppKit would try to bring back.
        isRestorable = false
        NotificationCenter.default.addObserver(self, selector: #selector(handleBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(handleResignKey),
                                               name: NSWindow.didResignKeyNotification, object: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func handleBecomeKey() {
        onBecomeKey()
    }

    @objc private func handleResignKey() {
        onResignKey()
    }
}

/// The panel's content: the surface plus the frame the in-window overlay used to draw, libghostty rendering
/// only the terminal. The solid backing keeps the quick terminal opaque even where the app is translucent.
private struct QuickTerminalPanelContent: View {
    let controller: QuickTerminalController
    let terminalColor: Color

    var body: some View {
        QuickTerminalPane(controller: controller)
            .background(terminalColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .accessibilityIdentifier("quick-terminal")
    }
}

/// Hosts the quick-terminal surface in the panel. Like `TerminalView`, it pulls the long-lived surface from
/// its owner (the app-level controller) rather than creating one, and never frees it on dismantle — hiding
/// the panel must keep the shell alive.
struct QuickTerminalPane: NSViewRepresentable {
    let controller: QuickTerminalController

    func makeNSView(context _: Context) -> GhosttySurfaceView {
        let view = controller.surface()
        controller.focus()
        return view
    }

    func updateNSView(_: GhosttySurfaceView, context _: Context) {}

    static func dismantleNSView(_: GhosttySurfaceView, coordinator _: ()) {
        // no-op: the controller owns the surface so it survives hide/show.
    }
}
