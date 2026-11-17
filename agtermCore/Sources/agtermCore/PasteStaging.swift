import Foundation
#if canImport(Musl)
import Musl
#endif

/// PasteStaging writes pasted items into a private folder and returns their paths: one fresh folder per paste,
/// one numbered subfolder per offered item, removed again when the paste fails.
public struct PasteStaging: Sendable {
    /// retention is how long a staged paste is kept; older ones are removed when the next paste is staged.
    public static let retention: TimeInterval = 24 * 60 * 60

    public let root: URL
    private let now: @Sendable () -> Date

    /// defaultRoot is `agterm/paste` in the user's caches directory: `~/Library/Caches` on macOS, `$XDG_CACHE_HOME`
    /// or `~/.cache` on Linux.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agterm", isDirectory: true).appendingPathComponent("paste", isDirectory: true)
    }

    public init(root: URL = PasteStaging.defaultRoot, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    /// reason is `error` worded for the user: a bundle or staging failure's own text, else Foundation's message rather
    /// than an `NSError` dump.
    public static func reason(for error: any Error) -> String {
        switch error {
        case let failure as PasteBundle.Failure: failure.description
        case let failure as Failure: failure.description
        default: error.localizedDescription
        }
    }

    /// Reply is what `agtermctl paste receive` prints: the staged paths, or the reason nothing was staged.
    public struct Reply: Codable, Equatable, Sendable {
        public let paths: [String]?
        public let error: String?

        public init(paths: [String]? = nil, error: String? = nil) {
            self.paths = paths
            self.error = error
        }

        /// init(result:) reads the ssh run of `paste receive`: its printed reply, else why there is none, an origin
        /// whose agtermctl predates the command included.
        public init(result: RemoteCommandResult) {
            if result.refusedArguments {
                self.init(error: "the origin's agterm is too old to receive pasted files")
                return
            }
            let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reply = try? JSONDecoder().decode(Reply.self, from: Data(line.utf8)), reply.paths != nil || reply.error != nil {
                self = result.status == 0 ? reply : Reply(error: reply.error ?? "the paste could not be copied")
                return
            }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(error: stderr.isEmpty ? "the paste could not be copied (exit \(result.status))" : stderr)
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsafeRoot(String)
        case exists(String)
        case system(String)

        public var description: String {
            switch self {
            case .unsafeRoot(let path): "paste folder \(path) is not a private directory"
            case .exists(let name): "\(name) appears twice in the paste"
            case .system(let message): message
            }
        }
    }

    /// receive stages the bundle read from `handle` and returns its items' paths in offer order.
    public func receive(from handle: FileHandle, limits: PasteBundle.Limits = .standard) throws -> [String] {
        var reader = PasteBundle.Reader(handle: handle, limits: limits)
        return try stage { batch in
            while let header = try reader.next() {
                try batch.create(header) { fd in try reader.copyBody(to: fd) }
            }
        }
    }

    /// stage writes one image named `name` and returns its path.
    public func stage(image: Data, name: String) throws -> String {
        guard let entry = try PasteBundle.entries(image: image, name: name).first else { throw PasteBundle.Failure.empty }
        let paths = try stage { batch in
            try batch.create(entry.header) { fd in try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: image) }
        }
        return paths[0]
    }

    private func stage(_ fill: (inout Batch) throws -> Void) throws -> [String] {
        try prepareRoot()
        prune()
        let folder = root.path + "/" + UUID().uuidString
        try Self.makeDirectory(folder)
        var batch = Batch(folder: folder)
        do {
            try fill(&batch)
            guard !batch.paths.isEmpty else { throw PasteBundle.Failure.empty }
            return batch.paths
        } catch {
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
    }

    // an existing root is accepted only as a real 0700 directory owned by this user, so a planted symlink or a
    // shared folder is never written into
    private func prepareRoot() throws {
        let path = root.path
        do {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw Failure.system("cannot create \(root.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw Failure.system("cannot create \(path): \(Self.errorText())") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw Failure.unsafeRoot(path)
        }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where UUID(uuidString: name) != nil {
            let path = root.path + "/" + name
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func makeDirectory(_ path: String) throws {
        guard mkdir(path, 0o700) == 0 else {
            if errno == EEXIST { throw Failure.exists((path as NSString).lastPathComponent) }
            throw Failure.system("cannot create \(path): \(errorText())")
        }
    }

    static func errorText() -> String { String(cString: strerror(errno)) }

    // every entry is created exclusively, so a name that differs only by case on a case-insensitive volume is
    // refused rather than merged
    struct Batch {
        let folder: String
        private(set) var paths: [String] = []

        init(folder: String) {
            self.folder = folder
        }

        mutating func create(_ header: PasteBundle.Header, body: (Int32) throws -> Void) throws {
            let container = folder + "/" + String(header.root)
            if header.root == paths.count {
                try PasteStaging.makeDirectory(container)
                paths.append(container + "/" + header.path)
            }
            let path = container + "/" + header.path
            guard header.kind == .file else { return try PasteStaging.makeDirectory(path) }
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                if errno == EEXIST { throw Failure.exists(header.path) }
                throw Failure.system("cannot create \(path): \(PasteStaging.errorText())")
            }
            defer { close(fd) }
            try body(fd)
        }
    }
}
