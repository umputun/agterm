import agtermCore
import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "NotificationManager")

/// Owns the macOS notification surface for terminal desktop notifications (OSC 9 / 777). `@preconcurrency`
/// on the `UNUserNotificationCenterDelegate` conformance keeps the delegate methods main-actor isolated
/// against the pre-concurrency UserNotifications API (as macterm does).
@MainActor
final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// The action hub used to navigate to a session/pane on a notification click. Set at launch by `agtermApp`;
    /// weak since `AppActions` outlives the manager only by app lifetime.
    weak var actions: AppActions?

    /// Resolves the firing surface's owning window id when building a notification identity, so a click can
    /// reopen a since-closed window. Set at launch by `agtermApp`; weak like `actions`.
    weak var library: WindowLibrary?

    /// Whether to post macOS banners (the General settings toggle, default on, set by `SettingsModel`). When
    /// off, the sidebar badge still tracks unseen notifications.
    var bannersEnabled = true

    /// How a delivered notification bounces the Dock icon (the Notifications settings picker, default `off`,
    /// set by `SettingsModel`). Independent of `bannersEnabled`, like the badge. `.once` is a single
    /// `.informationalRequest`, `.untilFocused` a `.criticalRequest` macOS auto-cancels on activation; both
    /// no-op while agterm is the active app, so a bounce only fires for one arriving in the background.
    var dockBounce: DockBounce = .off

    /// Name of the system sound attached to a delivered notification (the Notifications settings picker,
    /// default nil = silent, set by `SettingsModel`). Attached as `UNNotificationSound` on the banner content,
    /// NOT played directly, so it follows the banner: gated by `bannersEnabled` and the macOS notification
    /// authorization, and silenced by Do Not Disturb / Focus — unlike the raw `NSSound` agent-status sounds.
    var notificationSoundName: String?

    /// Register as the notification delegate and request alert + badge + sound authorization. Idempotent
    /// (the scene `.task` may re-run) and best-effort — a denial just means no banners. `.badge` is what lets
    /// `DockBadgeController` render the Dock count via `setBadgeCount`; without it the legacy
    /// `NSApp.dockTile.badgeLabel` is silently suppressed for agterm. `.sound` lets the configured sound play.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if !granted { logger.notice("notification authorization denied: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Handle a terminal desktop notification fired by `surface` (OSC 9 / 777). Resolves the owning session
    /// + pane, suppresses when that pane is focused and agterm is active, else posts a banner and bumps the
    /// unseen badge. Title falls back to the session name when the program sent none (OSC 9 has only a body).
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
        guard TerminalNotification.shouldDeliver(firingIsFocused: firingIsFocused, appActive: NSApp.isActive) else {
            logger.notice("notify: session \(session.id, privacy: .public) is the focused pane; suppressed")
            return
        }
        guard let effectiveTitle = library?.store(forSession: session.id)?.recordNotificationEvent(
            forSession: session.id, title: title, body: body
        ) else { return }

        // the badge always tracks the unseen notification; the macOS banner is gated by the toggle.
        session.unseenCount += 1
        bounceDock()
        guard bannersEnabled else {
            logger.notice("""
                notify: badge bumped for session \(session.id, privacy: .public), but no banner — \
                "Show notification banners" is off in Settings > Notifications
                """)
            return
        }
        logger.notice("notify: posting banner for session \(session.id, privacy: .public)")

        let content = UNMutableNotificationContent()
        content.title = effectiveTitle
        content.body = body
        content.sound = notificationSound
        // the request identifier is the identity (`<windowID>:<sessionID>:<pane>`): it coalesces repeats from
        // the same pane and carries the target a click decodes.
        let identity = TerminalNotification.identity(windowID: windowID, sessionID: session.id, pane: pane)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identity, content: content, trigger: nil)) { error in
            if let error { logger.error("add failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Post a desktop notification for a session via the control `notify` command rather than a terminal OSC.
    /// NO focus-suppression — the caller asked for it, so it always bumps the badge and posts a banner (gated
    /// only by `bannersEnabled`), attributed to the session's primary pane so a click reveals it. False, and
    /// nothing sent, when no open window owns the session (no click-reveal identity to build).
    @discardableResult
    func send(toSession session: Session, title: String, body: String) -> Bool {
        guard let windowID = library?.windowID(forSession: session.id) else { return false }
        guard let effectiveTitle = library?.store(forSession: session.id)?.recordNotificationEvent(
            forSession: session.id, title: title, body: body
        ) else { return false }
        session.unseenCount += 1
        bounceDock()
        guard bannersEnabled else {
            logger.notice("""
                send: badge bumped for session \(session.id, privacy: .public), but no banner — \
                "Show notification banners" is off in Settings > Notifications
                """)
            return true
        }
        logger.notice("send: posting banner for session \(session.id, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = effectiveTitle
        content.body = body
        content.sound = notificationSound
        let identity = TerminalNotification.identity(windowID: windowID, sessionID: session.id, pane: .main)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identity, content: content, trigger: nil)) { error in
            if let error { logger.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }

    /// Remove a session's delivered banners from Notification Center on focus, so one you navigated to doesn't
    /// linger. Removes every pane's identifier. No-op when the session's window isn't open.
    func clearDelivered(sessionID: UUID) {
        guard let windowID = library?.windowID(forSession: sessionID) else {
            logger.debug("clearDelivered: no open window owns session \(sessionID, privacy: .public); nothing to clear")
            return
        }
        let identifiers = PaneRole.allCases.map { TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: $0) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Post a failure banner for a custom command that exited non-zero or failed to spawn. Not tied to a
    /// surface, so no focus/window gating; a fixed identifier coalesces repeated failures of one command.
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

    /// Post a banner when the keymap parsed with problems (parse errors or cross-section conflicts), visible
    /// without opening Settings. App-level like `notifyCommandFailure`; a fixed identifier coalesces reloads.
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

    /// Post a banner when the ghostty config reloaded with problems (parse errors or invalid keys), visible
    /// without digging through the log. The count spans ALL config sources (bundled defaults, global
    /// `~/.config/ghostty/config`, agterm-scoped `ghostty.conf`, the UI settings conf) — libghostty
    /// diagnostics carry no source-file attribution, so the banner does NOT blame `ghostty.conf`. App-level
    /// like `notifyKeymapDiagnostics`, a fixed identifier coalescing reloads.
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

    /// Bounce the Dock icon per `dockBounce`; macOS auto-cancels `.untilFocused` on activation, so there is
    /// no cancel bookkeeping.
    private func bounceDock() {
        switch dockBounce {
        case .off: return
        case .once: NSApp.requestUserAttention(.informationalRequest)
        case .untilFocused: NSApp.requestUserAttention(.criticalRequest)
        }
    }

    /// The `UNNotificationSound` for the configured name, nil when unset (silent, the default). `default`/`beep`
    /// map to the system alert sound; any other value names a file the OS resolves against the standard
    /// locations (`~/Library/Sounds` through `/System/Library/Sounds`), with `.aiff` assumed when the name
    /// carries no extension — the system sounds' format, and how the Settings picker stores them.
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

    /// Present banners, with their attached sound, even while agterm is active — the focused-pane case is
    /// dropped before delivery. Without `.sound` a foreground banner is silent, so a session you are NOT
    /// looking at would only ding while backgrounded.
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A banner was clicked: bring agterm forward and navigate to the firing session/pane, decoded from the
    /// request identifier. A malformed identifier or closed session just leaves the app active.
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        NSApp.activate(ignoringOtherApps: true)
        guard let target = TerminalNotification.parseIdentity(response.notification.request.identifier) else { return }
        actions?.reveal(windowID: target.windowID, sessionID: target.sessionID, pane: target.pane)
    }
}
