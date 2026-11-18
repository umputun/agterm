import Foundation

public enum LaunchHandoff {
    /// `kInternetEventClass` and `kAEGetURL`, both 'GURL', which Foundation does not export.
    private static let getURL: UInt32 = "GURL".utf8.reduce(0) { ($0 << 8) | UInt32($1) }

    #if canImport(Darwin)
    /// Whether a window close is SwiftUI swapping its launch window: the close runs inside the open-URL or
    /// open-documents event that launched the app, which a user or control close never does.
    public static func isHandoff(event: NSAppleEventDescriptor?, launchFinished: Bool) -> Bool {
        guard !launchFinished, let event else { return false }
        if event.eventClass == getURL { return event.eventID == getURL }
        return event.eventClass == AEEventClass(kCoreEventClass) && event.eventID == AEEventID(kAEOpenDocuments)
    }
    #endif
}
