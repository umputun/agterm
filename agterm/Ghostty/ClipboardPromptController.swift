import AppKit
import agtermCore

/// ClipboardPromptController gates OSC 52 clipboard access a terminal program requests. It owns the
/// per-session `ClipboardPromptPolicy`: a remembered choice resolves immediately, otherwise it shows a
/// warning sheet and coalesces a flood of same-direction requests behind that one prompt so a program
/// looping OSC 52 can't stack a wall of sheets.
///
/// `@MainActor`: it touches AppKit and the non-Sendable policy. The C clipboard callbacks reach it by
/// hopping through `DispatchQueue.main.async`, which also defers the sheet past the current libghostty
/// tick so the modal run loop never re-enters it.
@MainActor
final class ClipboardPromptController {
    static let shared = ClipboardPromptController()

    private var policy = ClipboardPromptPolicy()
    private var pending: [ClipboardAccess: [(Bool) -> Void]] = [:]

    /// Resolve a clipboard access, prompting the user when there is no remembered session choice.
    /// `completion` runs on the main actor with the final allow/deny.
    func request(_ access: ClipboardAccess, completion: @escaping (Bool) -> Void) {
        switch policy.decision(for: access) {
        case .allow: completion(true)
        case .deny: completion(false)
        case .prompt: enqueue(access, completion: completion)
        }
    }

    private func enqueue(_ access: ClipboardAccess, completion: @escaping (Bool) -> Void) {
        if pending[access] != nil {
            // a sheet for this direction is already up — ride its decision instead of stacking another.
            pending[access]?.append(completion)
            return
        }
        pending[access] = [completion]
        presentPrompt(access)
    }

    private func presentPrompt(_ access: ClipboardAccess) {
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
            let waiters = self.pending.removeValue(forKey: access) ?? []
            for waiter in waiters { waiter(allowed) }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { resolve($0) }
        } else {
            resolve(alert.runModal())
        }
    }
}
