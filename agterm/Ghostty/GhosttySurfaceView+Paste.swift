import AppKit
import agtermCore

extension GhosttySurfaceView {
    /// PasteOutcome is how a paste ended, or the copy it still waits on.
    enum PasteOutcome {
        /// finished carries nil once pasted, else why nothing was.
        case finished(String?)
        case copying(Task<String?, Never>)

        var reason: String? {
            get async {
                switch self {
                case .finished(let reason): reason
                case .copying(let task): await task.value
                }
            }
        }
    }

    /// pasteClipboard pastes the general pasteboard, refusing before it is read while `pasteRefusal` holds, so a newer
    /// clipboard is never read under a running copy.
    @discardableResult
    func pasteClipboard() -> PasteOutcome {
        if let refusal = pasteRefusal { return .finished(refusal) }
        return paste(GhosttyCallbacks.pasteOffer(.general), drop: false)
    }

    /// pasteRefusal is why this pane takes no paste now: another Mac leads it, or an earlier paste is still copying.
    var pasteRefusal: String? {
        if leadCovered { return PaneLead.coveredRefusal }
        return pasteCopying ? PasteTransfer.stillCopying : nil
    }

    /// userPaste is the menu item's and ⌘V's paste; a copy reports its own failure, and a refusal is told here.
    func userPaste() {
        if case .finished(let reason?) = pasteClipboard() { PasteTransfer.shared.refuse(self, reason) }
    }

    /// paste inserts `offer`. What needs no copy goes the way it always went: libghostty's own paste for the clipboard,
    /// a bracketed insert for a drop. Files or an image the pane's program cannot open are copied first, and their paths
    /// go into this surface once the copy answers.
    func paste(_ offer: PasteOffer, drop: Bool) -> PasteOutcome {
        switch offer.route(onOrigin: linkClickRemoteSession != nil) {
        case .asIs:
            guard drop else { return .finished(performBindingAction("paste_from_clipboard") ? nil : Self.notRealized) }
            offer.asIsText.map { insertPasted(text: $0) }
            return .finished(nil)
        case .stageHere, .sendToOrigin:
            guard surface != nil else { return .finished(Self.notRealized) }
            pasteCopying = true
            return .copying(Task {
                defer { pasteCopying = false }
                switch await PasteTransfer.shared.text(offer, self) {
                case .success(let text):
                    guard surface != nil else { return Self.notRealized }
                    // a lead taken by another Mac during the copy would drop the insert unseen
                    guard !leadCovered else {
                        PasteTransfer.shared.refuse(self, PaneLead.coveredRefusal)
                        return PaneLead.coveredRefusal
                    }
                    insertPasted(text: text)
                    return nil
                case .failure(let failure):
                    return failure.reason
                }
            })
        }
    }

    private static let notRealized = "session not realized"
}
