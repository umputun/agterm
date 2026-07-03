import AppKit
import agtermCore

/// ClipboardPromptController gates OSC 52 clipboard access a terminal program requests. One shared
/// instance holds an app-session-scoped `ClipboardPromptPolicy` (the remembered allow/deny spans every
/// window and terminal session until agterm quits): a remembered choice resolves immediately, otherwise
/// it shows a warning sheet. Requests from the SAME (surface, direction) coalesce behind that one prompt
/// so a program looping OSC 52 can't stack a wall of sheets, while a request from a DIFFERENT surface
/// always gets its own prompt, so one Allow never authorizes another surface's read or write.
///
/// `@MainActor`: it touches AppKit and the controller's shared mutable state. The C clipboard callbacks reach it by
/// hopping through `DispatchQueue.main.async`, which also defers the sheet past the current libghostty
/// tick so the modal run loop never re-enters it.
@MainActor
final class ClipboardPromptController {
    static let shared = ClipboardPromptController()

    /// One in-flight sheet per (requesting surface, direction). Reads and gated writes both pass their
    /// surface as the requester; a nil requester (no surface available) coalesces by direction alone.
    private struct PromptKey: Hashable {
        let access: ClipboardAccess
        let requester: ObjectIdentifier?
    }

    /// A pending prompt: the waiters plus a STRONG reference to the requester, held until the sheet
    /// resolves. Retaining the requester stops its `ObjectIdentifier` from being reused by a newly
    /// allocated surface while the prompt is open, which would otherwise let that new surface's request
    /// hash to the same `PromptKey` and ride this prompt's decision.
    private struct Pending {
        let requester: AnyObject?
        var waiters: [(Bool) -> Void]
    }

    private var policy = ClipboardPromptPolicy()
    private var pending: [PromptKey: Pending] = [:]

    /// Resolve a clipboard access, prompting the user when there is no remembered session choice.
    /// `requester` scopes coalescing to a single surface and is retained while the prompt is open.
    /// `completion` runs on the main actor with the final allow/deny.
    func request(_ access: ClipboardAccess, requester: AnyObject? = nil, completion: @escaping (Bool) -> Void) {
        switch policy.decision(for: access) {
        case .allow: completion(true)
        case .deny: completion(false)
        case .prompt:
            let key = PromptKey(access: access, requester: requester.map(ObjectIdentifier.init))
            enqueue(key, requester: requester, completion: completion)
        }
    }

    private func enqueue(_ key: PromptKey, requester: AnyObject?, completion: @escaping (Bool) -> Void) {
        if pending[key] != nil {
            // a sheet for this (surface, direction) is already up — ride its decision instead of stacking.
            pending[key]?.waiters.append(completion)
            return
        }
        pending[key] = Pending(requester: requester, waiters: [completion])
        presentPrompt(key)
    }

    private func presentPrompt(_ key: PromptKey) {
        let access = key.access
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = access == .read ? "Allow a program to read the clipboard?" : "Allow a program to set the clipboard?"
        alert.informativeText = access == .read
            ? "A program running in the terminal is trying to read your clipboard contents (OSC 52), which could expose passwords or other copied data."
            : "A program running in the terminal is trying to replace your clipboard contents (OSC 52)."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again this session"

        let resolve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            let allowed = response == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on { self.policy.remember(access, allow: allowed) }
            let entry = self.pending.removeValue(forKey: key)
            for waiter in entry?.waiters ?? [] { waiter(allowed) }
        }

        // attach to the REQUESTING surface's own window when we can, so the prompt lands on the terminal
        // whose program triggered it (not some other key window); fall back to key/main.
        let requesterWindow = (pending[key]?.requester as? NSView)?.window
        if let window = requesterWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { resolve($0) }
        } else {
            resolve(alert.runModal())
        }
    }
}
