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

    public static let filename = "browser-profile"

    private let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent(Self.filename)
    }

    /// exists is true once an identifier was written, whatever the file holds now.
    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// identifier reads the profile id, writing a new one only when the file is missing. A file that cannot
    /// be read or holds anything else throws and is left alone: a regenerated id would orphan the store
    /// holding every saved login.
    public func identifier() throws -> UUID {
        guard exists else { return try create() }
        guard let data = try? Data(contentsOf: file) else { throw Failure.unreadable(file.path) }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: text) else { throw Failure.malformed(file.path) }
        return id
    }

    private func create() throws -> UUID {
        let id = UUID()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(id.uuidString)\n".utf8).write(to: file, options: .atomic)
        return id
    }
}
