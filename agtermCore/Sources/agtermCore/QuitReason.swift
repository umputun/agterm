import Foundation

public enum QuitReason {
    private static let shutDown = fourCharacterCode("shut")
    private static let restart = fourCharacterCode("rest")
    private static let reallyLogOut = fourCharacterCode("rlgo")

    /// Whether a quit came from the system (shutdown, restart, logout) rather than from the user, read
    /// off the quit event's `kAEQuitReason` attribute. A nil event, an event with no reason attribute,
    /// and a scripted quit all answer false, so the caller keeps its confirmation.
    ///
    /// The read lives here rather than in the app target so the whole seam is testable, and because
    /// building the keyword by hand hides a trap: `AEKeyword` is `FourCharCode`, which is `UInt32`, so
    /// `AEKeyword("why?")` resolves to `UInt32.init?(String)`, the decimal parser, and is always nil.
    public static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let reason = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return false }
        return skipsConfirmation(typeCode: reason.typeCodeValue)
    }

    public static func skipsConfirmation(typeCode: UInt32) -> Bool {
        typeCode == shutDown || typeCode == restart || typeCode == reallyLogOut
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
