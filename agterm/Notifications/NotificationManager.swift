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

    /// The window each moved session landed in, keyed by session. `windowID(forSession:)` answers only for
    /// open windows, so this is what still tells a move from a plain window close once the destination has
    /// closed too. Dropped once an open window other than the recorded one owns the session, and swept with
    /// the banners it exists to retarget, so a session closed after its move leaves nothing behind.
    private var movedSessionWindows: [UUID: UUID] = [:]

    /// When each banner identity was last submitted, and how many sweeps are still waiting on their
    /// delivered-set query. An identity is reusable, so a banner posted after a sweep's query can replace
    /// one that query named; removing by identifier would then take the newer banner. Only an in-flight
    /// sweep can be spared by a record, so the map holds only what was posted while one was in flight.
    private var lastPostedAt: [String: Date] = [:]
    private var sweepsInFlight = 0

    /// Sessions with a banner submission or a sweep still outstanding, counted so concurrent ones nest. No
    /// delivered set names their banners yet an `add` completion or a click can still ask where the session
    /// lives, so a sweep must keep their move records however empty its own snapshot looks.
    private var unsettledSessions: [UUID: Int] = [:]

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
        guard let windowID = openWindowID(forSession: session.id) else {
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
        post(identity: identity, content: content, sessionID: session.id)
    }

    /// Post a desktop notification for a session via the control `notify` command rather than a terminal OSC.
    /// NO focus-suppression — the caller asked for it, so it always bumps the badge and posts a banner (gated
    /// only by `bannersEnabled`), attributed to the session's primary pane so a click reveals it. False, and
    /// nothing sent, when no open window owns the session (no click-reveal identity to build).
    @discardableResult
    func send(toSession session: Session, title: String, body: String) -> Bool {
        guard let windowID = openWindowID(forSession: session.id) else { return false }
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
        post(identity: identity, content: content, sessionID: session.id)
        return true
    }

    /// Submit the banner request, then retire it if the session changed windows while the add was in flight.
    /// `retireBanners` on a move only sees what is already delivered, so a request submitted a beat earlier
    /// would survive it and send a click to the window the session just left.
    private func post(identity: String, content: UNNotificationContent, sessionID: UUID) {
        // a sweep starting later has a cutoff past this post, so with none in flight no record can spare
        // anything: drop them here rather than let notification traffic alone grow the map.
        if sweepsInFlight == 0 { lastPostedAt.removeAll() }
        lastPostedAt[identity] = Date()
        beginUnsettled(sessionID)
        let request = UNNotificationRequest(identifier: identity, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async {
                NotificationManager.shared.finishPost(identity: identity, sessionID: sessionID, error: error)
            }
        }
    }

    /// Release the submission's hold, then retire the banner if the session changed windows while the add
    /// was in flight.
    private func finishPost(identity: String, sessionID: UUID, error: (any Error)?) {
        endUnsettled(sessionID)
        if let error {
            logger.error("banner add failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let current = currentWindowID(forSession: sessionID)
        guard TerminalNotification.isStale(identity: identity, currentWindowID: current) else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identity])
        center.removePendingNotificationRequests(withIdentifiers: [identity])
    }

    private func beginUnsettled(_ sessionID: UUID) {
        unsettledSessions[sessionID, default: 0] += 1
    }

    private func endUnsettled(_ sessionID: UUID) {
        guard let count = unsettledSessions[sessionID] else { return }
        if count > 1 { unsettledSessions[sessionID] = count - 1 } else { unsettledSessions.removeValue(forKey: sessionID) }
    }

    /// Retire the moved session's banners that predate the move: they carry the SOURCE window's identity, so a
    /// click would reopen the window the session just left. Recording the destination lets an `add` still in
    /// flight, a later delivery, and a click all retarget the session even after that destination closes.
    func retireBanners(forMovedSession sessionID: UUID, destinationWindowID: UUID) {
        movedSessionWindows[sessionID] = destinationWindowID
        removeDelivered(sessionID: sessionID, staleRelativeTo: destinationWindowID)
    }

    /// The open window owning a session, and the one place a stale move record is dropped: an open owner
    /// other than the recorded destination means the session reached it without a move (Open Recent,
    /// restore). Every caller that observes an owner comes through here, so the record goes while a window
    /// still contradicts it rather than once both have closed and only the record answers.
    private func openWindowID(forSession sessionID: UUID) -> UUID? {
        guard let open = library?.windowID(forSession: sessionID) else { return nil }
        if movedSessionWindows[sessionID] != open { movedSessionWindows.removeValue(forKey: sessionID) }
        return open
    }

    /// The window hosting a session now: its open owner, else the window it was last moved into. Nil when
    /// neither answers — a session whose window merely closed, whose banner still reopens that window.
    private func currentWindowID(forSession sessionID: UUID) -> UUID? {
        guard let open = openWindowID(forSession: sessionID) else {
            // the recorded destination is open yet no longer holds the session, so the session left it by a
            // route that never records one (closed, reopened elsewhere): the record is answering for a
            // window it no longer knows, and nil — "cannot tell" — is the honest answer.
            if let recorded = movedSessionWindows[sessionID], library?.isOpen(recorded) == true {
                movedSessionWindows.removeValue(forKey: sessionID)
                return nil
            }
            return movedSessionWindows[sessionID]
        }
        return open
    }

    /// Remove a session's delivered banners from Notification Center on focus, so one you navigated to doesn't
    /// linger.
    func clearDelivered(sessionID: UUID) {
        removeDelivered(sessionID: sessionID, staleRelativeTo: nil)
    }

    /// Remove a session's delivered banners, matched by session id rather than by rebuilding identifiers from
    /// the current window: a cross-window move leaves banners keyed to the SOURCE window, which the
    /// destination's identifiers would never match. `staleRelativeTo` spares the ones that window still owns,
    /// and the `cutoff` everything delivered after this sweep started; `TerminalNotification.shouldSweep`
    /// owns both rules.
    private func removeDelivered(sessionID: UUID, staleRelativeTo windowID: UUID?) {
        let cutoff = Date()
        sweepsInFlight += 1
        beginUnsettled(sessionID)
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let entries = delivered.map { (identity: $0.request.identifier, deliveredAt: $0.date) }
            DispatchQueue.main.async {
                let manager = NotificationManager.shared
                let identifiers = manager.sweepable(entries, sessionID: sessionID, staleRelativeTo: windowID,
                                                    cutoff: cutoff)
                guard !identifiers.isEmpty else { return }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    /// The delivered banners this sweep may take, judged against `lastPostedAt` on the main actor so a
    /// banner posted since the query cannot be removed by the identifier it reused. Also the move records'
    /// only garbage collection — the delivered set plus the unsettled sessions is what says which are still
    /// reachable. Ends the sweep's in-flight window: with none left, no record can spare anything again.
    private func sweepable(_ delivered: [(identity: String, deliveredAt: Date)], sessionID: UUID,
                           staleRelativeTo windowID: UUID?, cutoff: Date) -> [String] {
        defer {
            endUnsettled(sessionID)
            sweepsInFlight -= 1
            if sweepsInFlight == 0 { lastPostedAt.removeAll() }
        }
        movedSessionWindows = TerminalNotification.retainedMoveRecords(
            movedSessionWindows, delivered: delivered.map(\.identity), unsettled: Set(unsettledSessions.keys)
        )
        return delivered.map {
            TerminalNotification.DeliveredBanner(identity: $0.identity, deliveredAt: $0.deliveredAt,
                                                 lastPostedAt: lastPostedAt[$0.identity])
        }.filter {
            TerminalNotification.shouldSweep($0, sessionID: sessionID, staleRelativeTo: windowID, cutoff: cutoff)
        }.map(\.identity)
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

    /// Which of the session's surfaces fired, by identity against its three slots. Pane overlays are absent
    /// on purpose: `notify` needs `view.session`, which only the two pane factories assign, so no overlay
    /// surface reaches here. Wiring pane-overlay notifications would need that link, not another slot test.
    private func paneRole(of view: GhosttySurfaceView, in session: Session) -> PaneRole {
        if view === (session.splitSurface as? GhosttySurfaceView) { return .split }
        if view === (session.overlaySurface as? GhosttySurfaceView) { return .overlay }
        return .main
    }

    /// Present banners, with their attached sound, even while agterm is active — the focused-pane case is
    /// dropped before delivery. Without `.sound` a foreground banner is silent, so a session you are NOT
    /// looking at would only ding while backgrounded.
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // delivery lands after `add` reports success, so a banner can arrive once its session already moved:
        // drop it here rather than send a click to the window it names.
        let identifier = notification.request.identifier
        let current = TerminalNotification.parseIdentity(identifier).flatMap { currentWindowID(forSession: $0.sessionID) }
        if TerminalNotification.isStale(identity: identifier, currentWindowID: current) {
            completionHandler([])
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    /// A banner was clicked: bring agterm forward and navigate to the firing session/pane, decoded from the
    /// request identifier. A malformed identifier or closed session just leaves the app active.
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        NSApp.activate(ignoringOtherApps: true)
        guard let target = TerminalNotification.parseIdentity(response.notification.request.identifier) else { return }
        // a banner delivered while agterm was in the background misses `willPresent`, so it can still name the
        // window a moved session left: click through to wherever that session lives now.
        let windowID = currentWindowID(forSession: target.sessionID) ?? target.windowID
        actions?.reveal(windowID: windowID, sessionID: target.sessionID, pane: target.pane)
    }
}
