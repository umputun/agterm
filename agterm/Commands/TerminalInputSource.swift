import AppKit
import agtermCore
import Carbon

/// A keyboard input source macOS can select, as the Settings picker lists it.
struct KeyboardInputSource: Equatable {
    let id: String
    let name: String
}

/// Holds the configured keyboard input source while a terminal surface has the keyboard and puts the
/// earlier one back when it does not. The only owner of Text Input Source selection in the app;
/// `InputSourceLock` decides, this performs.
///
/// Selection is system-wide, so the restore is what keeps other applications on the user's own source.
/// A crash or a force quit runs no restore and leaves the configured source selected.
@MainActor
final class TerminalInputSource {
    static let shared = TerminalInputSource()

    private var lock = InputSourceLock()
    private var target: String?
    private var refreshScheduled = false
    private var stopped = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {
        // the quick terminal takes key without activating the app, so key-window changes are the edge to
        // watch, never application activation.
        observe(NotificationCenter.default, [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification])
        observe(DistributedNotificationCenter.default(),
                [NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                 NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)])
    }

    /// setTarget takes the configured source id, nil for off, and applies it to the current focus at once.
    func setTarget(_ id: String?) {
        target = id
        refresh()
    }

    /// requestRefresh re-evaluates on the next main-queue turn. Responder callbacks run before AppKit
    /// updates `window.firstResponder`, so a synchronous read there sees the previous owner.
    func requestRefresh() {
        guard !refreshScheduled, !stopped else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// stop restores the earlier source and ends enforcement for good, for application termination.
    func stop() {
        stopped = true
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        guard let current = Self.currentID(), let restore = lock.release(current: current) else { return }
        _ = Self.select(restore)
    }

    /// enabledSources lists the keyboard sources enabled in System Settings that macOS allows selecting.
    static func enabledSources() -> [KeyboardInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard flag(source, kTISPropertyInputSourceIsSelectCapable), let id = string(source, kTISPropertyInputSourceID) else {
                return nil
            }
            return KeyboardInputSource(id: id, name: string(source, kTISPropertyLocalizedName) ?? id)
        }
    }

    private func refresh() {
        refreshScheduled = false
        guard !stopped, target != nil || lock.baseline != nil, let current = Self.currentID() else { return }
        let enabled = Set(Self.enabledSources().map(\.id))
        guard let wanted = lock.reconcile(terminalFocused: Self.terminalHoldsKeyboard(), target: target,
                                          enabled: enabled, current: current) else { return }
        if !Self.select(wanted) { lock.selectionFailed() }
    }

    private func observe(_ center: NotificationCenter, _ names: [NSNotification.Name]) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRefresh() }
            }
            observers.append((center, token))
        }
    }

    private static func terminalHoldsKeyboard() -> Bool {
        // nil at launch: the settings model applies the saved source before the application object exists.
        guard let app = NSApp as NSApplication?,
              let responder = app.windows.first(where: \.isKeyWindow)?.firstResponder as? GhosttySurfaceView else {
            return false
        }
        return responder.surface != nil
    }

    private static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    private static func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let source = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
