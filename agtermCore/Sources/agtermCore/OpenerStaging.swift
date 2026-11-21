import Foundation

/// OpenerStaging keeps the private copies of files an `open` rule runs on when they live on another host:
/// `<root>/<uuid>/<name>`, root and folder 0700, each copy kept an hour so the rule's program can still read it.
public struct OpenerStaging: Sendable {
    public static let retention: TimeInterval = 60 * 60

    public let root: URL
    private let now: @Sendable () -> Date

    /// defaultRoot is `agterm/open` in the user's caches directory.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agterm", isDirectory: true).appendingPathComponent("open", isDirectory: true)
    }

    public init(root: URL = OpenerStaging.defaultRoot, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsafeName
        case tooLarge
        case sizeMismatch
        case system(String)

        public var description: String {
            switch self {
            case .unsafeName: "the offered name is not a plain file name"
            case .tooLarge: "the offered file is larger than its page could read"
            case .sizeMismatch: "the file did not arrive at its offered size"
            case .system(let message): message
            }
        }
    }

    /// stage writes `data`, received for a file offered as `name` of `size` bytes, and returns the copy's path. The
    /// name and size are another host's word: a name that is not a plain component, a size past the cap of the page
    /// that name opens as, or bytes of another length stage nothing.
    public func stage(name: String, data: Data, size: Int) throws -> String {
        guard PasteBundle.isSafeComponent(name) else { throw Failure.unsafeName }
        guard let cap = LinkPolicy.previewBytes(forFileName: name), size >= 0, size <= cap else { throw Failure.tooLarge }
        guard data.count == size else { throw Failure.sizeMismatch }
        do {
            try PasteStaging.prepareRoot(root)
        } catch let failure as PasteStaging.Failure {
            throw Failure.system(failure.description)
        }
        sweep()
        let folder = root.path + "/" + UUID().uuidString
        guard mkdir(folder, 0o700) == 0 else { throw Failure.system("cannot create \(folder): \(PasteStaging.errorText())") }
        let path = folder + "/" + name
        do {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.system("cannot create \(path): \(PasteStaging.errorText())") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw Failure.system("cannot write \(path): \(error.localizedDescription)")
            }
            return path
        } catch {
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
    }

    /// sweep removes copies older than `retention`, and nothing under a root that is not this user's private folder.
    public func sweep() {
        guard PasteStaging.isPrivateDirectory(root.path) else { return }
        PasteStaging.prune(root, before: now().addingTimeInterval(-Self.retention))
    }

    /// remove deletes the folder holding the copy at `path`, and nothing that is not a copy staged here.
    public func remove(_ path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        guard (folder as NSString).deletingLastPathComponent == root.path, PasteStaging.isPrivateDirectory(root.path),
              UUID(uuidString: (folder as NSString).lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(atPath: folder)
    }
}
