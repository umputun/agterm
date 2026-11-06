import Foundation

public enum QuitReason {
    private static let shutDown = fourCharacterCode("shut")
    private static let restart = fourCharacterCode("rest")
    private static let reallyLogOut = fourCharacterCode("rlgo")

    #if canImport(Darwin)
    /// Whether a quit came from the system (shutdown, restart, logout) rather than from the user. A nil
    /// event, an event with no reason, and a scripted quit all answer false, so the caller keeps its
    /// confirmation.
    public static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        // an attribute, not a param, despite AERegistry.h calling kAEQuitReason a parameter: loginwindow's
        // -[LogoutUtilities addLogOutAttibutesToQuitAppleEvent:] writes it with AEPutAttributePtr.
        guard let reason = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return false }
        return skipsConfirmation(typeCode: reason.typeCodeValue)
    }
    #endif

    static func skipsConfirmation(typeCode: UInt32) -> Bool {
        typeCode == shutDown || typeCode == restart || typeCode == reallyLogOut
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
