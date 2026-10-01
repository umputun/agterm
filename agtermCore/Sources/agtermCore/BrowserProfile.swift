import Foundation

/// BrowserProfile names the persistent browser store of one agterm state directory. WebKit keeps an
/// identified store under the app's Library folder keyed by this id alone, so the id file is what keeps two
/// state directories on separate stores.
public struct BrowserProfile: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .unreadable(let path): "browser profile cannot be read: \(path)"
            case .malformed(let path): "browser profile is not a UUID: \(path)"
            }
        }
    }

    static let filename = "browser-profile"
    // the values 0 and 1 are WebKit's own: it raises an exception for either instead of returning an error
    private static let reserved: Set<UUID> = [
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
    ]

    private let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent(Self.filename)
    }

    /// existingIdentifier reads the profile id without creating one, nil only when the file does not exist.
    /// A file that cannot be read or holds anything else throws and is left alone: a regenerated id would
    /// orphan the store holding every saved login.
    public func existingIdentifier() throws -> UUID? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw Failure.unreadable(file.path)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: text), !Self.reserved.contains(id) else { throw Failure.malformed(file.path) }
        return id
    }

    /// identifier reads the profile id, writing a new one only when the file does not exist.
    public func identifier() throws -> UUID {
        if let id = try existingIdentifier() { return id }
        let id = UUID()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(id.uuidString)\n".utf8).write(to: file, options: .atomic)
        return id
    }
}
