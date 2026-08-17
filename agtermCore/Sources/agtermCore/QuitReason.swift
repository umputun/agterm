public enum QuitReason {
    private static let shutDown = fourCharacterCode("shut")
    private static let restart = fourCharacterCode("rest")
    private static let reallyLogOut = fourCharacterCode("rlgo")

    public static func skipsConfirmation(typeCode: UInt32) -> Bool {
        typeCode == shutDown || typeCode == restart || typeCode == reallyLogOut
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
