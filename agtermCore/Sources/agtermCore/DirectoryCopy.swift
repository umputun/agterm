import Foundation

/// DirectoryCopy copies a tree of directories and regular files, keeping contents and permission bits only.
/// Foundation's `copyItem` on Linux also copies the owner and group with `fchown`, which fails for a user outside the
/// source's group; the installed copy belongs to the user running the install either way.
enum DirectoryCopy {
    struct UnsupportedEntry: Error, Equatable {
        let path: String
    }

    static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        let mode = attributes[.posixPermissions] as? NSNumber
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?:
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            for name in try fm.contentsOfDirectory(atPath: source.path) {
                try copy(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        case .typeRegular?:
            try Data(contentsOf: source).write(to: destination)
        default:
            throw UnsupportedEntry(path: source.path)
        }
        if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path) }
    }
}
