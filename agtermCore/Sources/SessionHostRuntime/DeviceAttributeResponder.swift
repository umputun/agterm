// DA1/DA2 replies match zmx src/util.zig at ZMX_REV 8bab1f0173b07e79835ea372d749af3dbf0d0842.
struct DeviceAttributeResponder {
    private enum Prefix {
        case none, escape, csi, primary, secondary, secondaryZero
    }

    private var prefix = Prefix.none
    var holdsPartialQuery: Bool { prefix != .none }

    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var replies: [UInt8] = []
        for byte in bytes {
            switch (prefix, byte) {
            case (_, 0x1B): prefix = .escape
            case (.escape, 0x5B): prefix = .csi
            case (.csi, 0x30): prefix = .primary
            case (.csi, 0x3E): prefix = .secondary
            case (.secondary, 0x30): prefix = .secondaryZero
            case (.csi, 0x63), (.primary, 0x63):
                replies.append(contentsOf: "\u{1B}[?62;22c".utf8)
                prefix = .none
            case (.secondary, 0x63), (.secondaryZero, 0x63):
                replies.append(contentsOf: "\u{1B}[>1;10;0c".utf8)
                prefix = .none
            default: prefix = .none
            }
        }
        return replies
    }
}
