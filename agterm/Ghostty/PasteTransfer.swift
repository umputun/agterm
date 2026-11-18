import AppKit
import agtermCore

/// PasteTransfer turns a paste whose files or image must be copied first into the text its pane inserts. The app
/// points `text` at the control server once at launch; before that such a paste is refused.
@MainActor
struct PasteTransfer {
    static var shared = PasteTransfer()
    static let stillCopying = "a paste is still copying"

    /// text copies `offer` to where `surface`'s program can open it and answers the text to insert, or why not.
    var text: @MainActor (PasteOffer, GhosttySurfaceView) async -> Result<String, PasteFailure> = { _, _ in
        .failure(PasteFailure("paste is not available yet"))
    }
    /// refuse tells the user why a paste into `surface` did nothing.
    var refuse: @MainActor (GhosttySurfaceView, String) -> Void = { _, _ in NSSound.beep() }
    /// staging is where an image pasted into a pane running on this Mac is saved.
    var staging = PasteStaging()
    /// runner sends a bundle to an origin's `agtermctl paste receive`.
    var runner: any RemoteInputCommandRunner = RemoteCommandProcessRunner()
}

/// PasteFailure is why a paste inserted nothing, worded for the user.
struct PasteFailure: Error, Equatable {
    let reason: String

    init(_ reason: String) { self.reason = reason }
}
