import agtermCore
import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "NotificationManager")

/// Owns the macOS notification surface for terminal desktop notifications (OSC 9 / 777).
///
/// `@MainActor` and the `UNUserNotificationCenterDelegate`. `@preconcurrency` on the
/// conformance lets the delegate methods stay main-actor isolated against the pre-concurrency
/// UserNotifications API (matches macterm).
@MainActor
final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// The action hub used to navigate to a session/pane on a notification click. Set at launch by
    /// `agtermApp`; weak since `AppActions` outlives the manager only by app lifetime.
    weak var actions: AppActions?

    /// The window library, used to resolve the firing surface's owning window id when building a
    /// notification identity (so a click can reopen that window if it has since closed). Set at
    /// launch by `agtermApp`; weak for the same app-lifetime reason as `actions`.
    weak var library: WindowLibrary?

    /// Whether to post macOS banners (the General settings toggle, default on). When off, banners are
    /// suppressed but the sidebar badge still tracks unseen notifications. Set by `SettingsModel`.
    var bannersEnabled = true

    /// How a delivered notification bounces the Dock icon (the Notifications settings picker, default
    /// `off`). Independent of `bannersEnabled` — like the badge, a bounce can fire whether or not banners
    /// show. Set by `SettingsModel`. `.once` requests a single `.informationalRequest`; `.untilFocused` a
    /// `.criticalRequest` macOS auto-cancels when agterm becomes active — both no-op while agterm is the
    /// active app, so a bounce only fires when a notification arrives in the background.
    var dockBounce: DockBounce = .off

    /// Name of the system sound attached to a delivered notification (the Notifications settings
    /// picker, default nil = silent). Routed through the OS (`UNNotificationSound` on the banner's
    /// content), NOT played directly — so it follows the banner: gated by `bannersEnabled` and the
    /// macOS notification authorization, and silenced by Do Not Disturb / Focus, unlike the raw
    /// `NSSound` agent-status sounds. Set by `SettingsModel`.
    var notificationSoundName: String?

    /// Register as the notification delegate and request alert + badge + sound authorization.
    /// Idempotent; the scene `.task` may re-run. Best-effort: a denial just means no banners. The
    /// `.badge` option is what lets `DockBadgeController` render the Dock count via
    /// `UNUserNotificationCenter.setBadgeCount` — the legacy `NSApp.dockTile.badgeLabel` is silently
    /// suppressed for agterm without it. `.sound` is what lets the configured notification sound
    /// (attached to the banner's content) actually play.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if !granted { logger.notice("notification authorization denied: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Handle a terminal desktop notification fired by `surface` (OSC 9 / 777). Resolves the owning
    /// session + pane, suppresses when that pane is focused and agterm is active, otherwise posts a
    /// banner (coalescing by session/pane) and bumps the session's unseen badge. Title falls back to
    /// the session name when the program sent an empty title (OSC 9 carries only a body).
    func notify(surface: GhosttySurfaceView, title: String, body: String) {
        guard let session = surface.session else { return }
        let pane = paneRole(of: surface, in: session)
        // the firing surface is always in an open window at fire time, so its window id is known.
        guard let windowID = library?.windowID(forSession: session.id) else {
            logger.notice("notify: no open window owns session \(session.id, privacy: .public); dropping")
            return
        }

        // strict first-responder check: suppress only when you are actually typing in this pane.
        let firingIsFocused = surface === (NSApp.keyWindow?.firstResponder as? GhosttySurfaceView)
        guard TerminalNotification.shouldDeliver(firingIsFocused: firingIsFocused, appActive: NSApp.isActive) else { return }

        // the badge always tracks the unseen notification; the macOS banner is gated by the toggle.
        session.unseenCount += 1
        bounceDock()
        guard bannersEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? session.displayName : title
        content.body = body
        content.sound = notificationSound
        // the request identifier is the identity (`<windowID>:<sessionID>:<pane>`): it both coalesces
        // repeats from the same pane and carries the target a click decodes via `TerminalNotification`.
        let identity = TerminalNotification.identity(windowID: windowID, sessionID: session.id, pane: pane)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identity, content: content, trigger: nil)) { error in
            if let error { logger.error("add failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Post a desktop notification for a session via the control channel (the `notify` command), as
    /// opposed to a terminal OSC. Unlike the OSC path there is NO focus-suppression — the caller asked
    /// for it explicitly, so it always bumps the badge and posts a banner (gated only by
    /// `bannersEnabled`). Attributed to the session's primary pane so a click reveals it. Returns false
    /// when no open window owns the session (the click-reveal identity can't be built) → not sent.
    @discardableResult
    func send(toSession session: Session, title: String, body: String) -> Bool {
        guard let windowID = library?.windowID(forSession: session.id) else { return false }
        session.unseenCount += 1
        bounceDock()
        guard bannersEnabled else { return true }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? session.displayName : title
        content.body = body
        content.sound = notificationSound
        let identity = TerminalNotification.identity(windowID: windowID, sessionID: session.id, pane: .main)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identity, content: content, trigger: nil)) { error in
            if let error { logger.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }

    /// Remove any delivered banners for a session from Notification Center — called when you focus
    /// the session, so a notification you've navigated to doesn't linger. Covers all of the session's
    /// panes by removing each possible `<windowID>:<sessionID>:<paneRole>` identifier. No-op when the
    /// session's window isn't open (nothing it delivered could be lingering).
    func clearDelivered(sessionID: UUID) {
        guard let windowID = library?.windowID(forSession: sessionID) else {
            logger.debug("clearDelivered: no open window owns session \(sessionID, privacy: .public); nothing to clear")
            return
        }
        let identifiers = PaneRole.allCases.map { TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: $0) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Post a failure banner for a custom command that exited non-zero or failed to spawn. Unlike a
    /// terminal notification it isn't tied to a surface, so it always posts when banners are enabled
    /// (no focus/window gating); a fixed identifier coalesces repeated failures of the same command.
    func notifyCommandFailure(name: String, detail: String) {
        guard bannersEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Command failed"
        content.body = "\(name) (\(detail))"
        let request = UNNotificationRequest(identifier: "command-failure:\(name)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("command-failure banner add failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Post a banner when the keymap parsed with problems (parse errors or cross-section conflicts), so
    /// they're visible without opening Settings. Session-less and app-level, like `notifyCommandFailure`:
    /// no focus/window gating; a fixed identifier coalesces repeated reloads to a single banner.
    func notifyKeymapDiagnostics(count: Int) {
        guard bannersEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Keymap"
        content.body = "\(count) issue\(count == 1 ? "" : "s") — see Settings ▸ Key Mapping"
        let request = UNNotificationRequest(identifier: "keymap-diagnostics", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("keymap-diagnostics banner add failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Post a banner when the ghostty config reloaded with problems (parse errors or invalid keys), so
    /// they're visible without digging through the log. The count spans ALL config sources (bundled
    /// defaults, the global `~/.config/ghostty/config`, the agterm-scoped `ghostty.conf`, and the UI
    /// settings conf) because libghostty diagnostics carry no source-file attribution, so the banner does
    /// NOT blame `ghostty.conf` specifically. Session-less and app-level, like `notifyKeymapDiagnostics`:
    /// no focus/window gating; a fixed identifier coalesces repeated reloads to a single banner.
    func notifyConfigDiagnostics(count: Int) {
        guard bannersEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Config"
        content.body = "\(count) issue\(count == 1 ? "" : "s") in ghostty config — see Console, then Reload Config"
        let request = UNNotificationRequest(identifier: "config-diagnostics", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("config-diagnostics banner add failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Bounce the Dock icon for a background notification per the configured mode. `.once` is a single
    /// `.informationalRequest`; `.untilFocused` a `.criticalRequest` that bounces until agterm becomes active
    /// (macOS auto-cancels it then, so there is no cancel bookkeeping). Both are automatically a no-op while
    /// agterm is the active app, so a notification for a session you're already looking at never bounces.
    private func bounceDock() {
        switch dockBounce {
        case .off: return
        case .once: NSApp.requestUserAttention(.informationalRequest)
        case .untilFocused: NSApp.requestUserAttention(.criticalRequest)
        }
    }

    /// The `UNNotificationSound` for the configured name, or nil when unset (silent, the default).
    /// `default`/`beep` map to the system alert sound; any other value names a sound file the OS
    /// resolves against the standard sound locations (`~/Library/Sounds` through
    /// `/System/Library/Sounds`), with `.aiff` assumed when the name carries no extension — the system
    /// sounds' format, and how the Settings picker stores them.
    private var notificationSound: UNNotificationSound? {
        guard let name = notificationSoundName, !name.isEmpty else { return nil }
        if name == "default" || name == "beep" { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(name.contains(".") ? name : name + ".aiff"))
    }

    /// Which of the session's surfaces fired, by identity against its three slots.
    private func paneRole(of view: GhosttySurfaceView, in session: Session) -> PaneRole {
        if view === (session.splitSurface as? GhosttySurfaceView) { return .split }
        if view === (session.overlaySurface as? GhosttySurfaceView) { return .overlay }
        return .main
    }

    /// Present banners — with their attached sound — even while agterm is the active app (the
    /// focused-pane case is dropped before delivery, so anything reaching here should show). Without
    /// `.sound` a foreground banner would show silently, so a notification from a session you're NOT
    /// looking at would only ding while agterm is backgrounded.
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A banner was clicked: bring agterm forward and navigate to the firing session/pane (decoded from
    /// the request identifier). A malformed identifier or closed session just leaves the app active.
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        NSApp.activate(ignoringOtherApps: true)
        guard let target = TerminalNotification.parseIdentity(response.notification.request.identifier) else { return }
        actions?.reveal(windowID: target.windowID, sessionID: target.sessionID, pane: target.pane)
    }
}
