import Foundation

/// PasteBundle is the wire format for pasted files, folders and a clipboard image: a version line, then per entry
/// one JSON header line followed by `size` raw bytes for a file.
public enum PasteBundle {
    public static let versionLine = "agterm-paste 1"
    /// maxHeaderBytes bounds a header line, so a stream with no newline is refused before it is buffered whole.
    public static let maxHeaderBytes = 64 * 1024
    static let chunkBytes = 1 << 20

    public struct Limits: Equatable, Sendable {
        public let totalBytes: Int64
        public let entries: Int

        public init(totalBytes: Int64, entries: Int) {
            self.totalBytes = totalBytes
            self.entries = entries
        }

        public static let standard = Limits(totalBytes: 100 * 1024 * 1024, entries: 10_000)
    }

    public enum Kind: String, Codable, Sendable {
        case file
        case dir
    }

    /// Header names one entry: `root` is the offered item's index, `path` its relative path whose first component
    /// is that item's own name.
    public struct Header: Codable, Equatable, Sendable {
        public let root: Int
        public let path: String
        public let kind: Kind
        public let size: Int64

        public init(root: Int, path: String, kind: Kind, size: Int64 = 0) {
            self.root = root
            self.path = path
            self.kind = kind
            self.size = size
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooLarge(Int64)
        case tooManyEntries(Int)
        case empty
        case unsupported(String)
        case badPath(String)
        case duplicate(String)
        case unsupportedVersion
        case headerTooLong
        case malformedHeader
        case truncated
        case unreadable(String)

        public var description: String {
            switch self {
            case .tooLarge(let limit): "too large to paste (limit \(limit / 1024 / 1024) MB)"
            case .tooManyEntries(let limit): "too many files to paste (limit \(limit))"
            case .empty: "nothing to paste"
            case .unsupported(let name): "\(name) is not a regular file or folder"
            case .badPath(let path): "unsafe path in paste: \(path)"
            case .duplicate(let path): "duplicate entry in paste: \(path)"
            case .unsupportedVersion: "unsupported paste format"
            case .headerTooLong: "paste entry header too long"
            case .malformedHeader: "malformed paste entry header"
            case .truncated: "paste data ended early"
            case .unreadable(let name): "cannot read \(name)"
            }
        }
    }

    /// Entry is one header plus where the sender reads its bytes from.
    public struct Entry: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            case file(URL)
            case data(Data)
            case none
        }

        public let header: Header
        public let source: Source
    }

    /// entries walks `files` in offer order into bundle entries, one root per item. A folder's symlinks and special
    /// files are skipped, never followed; an offered item that is neither a regular file nor a folder throws. The
    /// walk stops at the first exceeded limit, before reading the rest of a large folder.
    public static func entries(files: [URL], limits: Limits = .standard) throws -> [Entry] {
        var counter = LimitCounter(limits: limits)
        var result: [Entry] = []
        for (root, url) in files.enumerated() {
            let name = url.lastPathComponent
            guard isSafeComponent(name) else { throw Failure.badPath(name) }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard let values, values.isSymbolicLink != true else { throw Failure.unsupported(name) }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                try counter.add(size)
                result.append(Entry(header: Header(root: root, path: name, kind: .file, size: size), source: .file(url)))
                continue
            }
            guard values.isDirectory == true else { throw Failure.unsupported(name) }
            try counter.add(0)
            result.append(Entry(header: Header(root: root, path: name, kind: .dir), source: .none))
            result += try folderEntries(url, root: root, name: name, counter: &counter)
        }
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    /// entries packs one image as a single-file bundle named `name`.
    public static func entries(image: Data, name: String, limits: Limits = .standard) throws -> [Entry] {
        guard isSafeComponent(name) else { throw Failure.badPath(name) }
        var counter = LimitCounter(limits: limits)
        try counter.add(Int64(image.count))
        return [Entry(header: Header(root: 0, path: name, kind: .file, size: Int64(image.count)), source: .data(image))]
    }

    /// write streams `entries` to `handle` in the bundle format; a file that shrank since the walk throws.
    public static func write(_ entries: [Entry], to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try handle.write(contentsOf: Data((versionLine + "\n").utf8))
        for entry in entries {
            try handle.write(contentsOf: encoder.encode(entry.header) + Data("\n".utf8))
            switch entry.source {
            case .none: continue
            case .data(let data): try handle.write(contentsOf: data)
            case .file(let url): try copy(url, size: entry.header.size, to: handle)
            }
        }
    }

    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func folderEntries(_ folder: URL, root: Int, name: String, counter: inout LimitCounter) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var failed: URL?
        // an unreadable subfolder must fail the paste, never arrive as a copy with that part missing
        let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: []) { url, _ in
            failed = url
            return false
        }
        guard let walk else { throw Failure.unreadable(name) }
        let base = folder.standardizedFileURL.pathComponents.count
        var result: [Entry] = []
        for case let child as URL in walk {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { throw Failure.unreadable(child.lastPathComponent) }
            if values.isSymbolicLink == true { continue }
            let path = ([name] + child.standardizedFileURL.pathComponents.dropFirst(base)).joined(separator: "/")
            if values.isDirectory == true {
                try counter.add(0)
                result.append(Entry(header: Header(root: root, path: path, kind: .dir), source: .none))
            } else if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                try counter.add(size)
                result.append(Entry(header: Header(root: root, path: path, kind: .file, size: size), source: .file(child)))
            }
        }
        if let failed { throw Failure.unreadable(failed.lastPathComponent) }
        return result
    }

    private static func copy(_ url: URL, size: Int64, to handle: FileHandle) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        var left = size
        while left > 0 {
            guard let chunk = try source.read(upToCount: Int(min(left, Int64(chunkBytes)))), !chunk.isEmpty else {
                throw Failure.unreadable(url.lastPathComponent)
            }
            try handle.write(contentsOf: chunk)
            left -= Int64(chunk.count)
        }
    }
}

struct LimitCounter {
    let limits: PasteBundle.Limits
    private(set) var bytes: Int64 = 0
    private(set) var entries = 0

    init(limits: PasteBundle.Limits) {
        self.limits = limits
    }

    mutating func add(_ size: Int64) throws {
        entries += 1
        guard entries <= limits.entries else { throw PasteBundle.Failure.tooManyEntries(limits.entries) }
        guard size >= 0, size <= limits.totalBytes - bytes else { throw PasteBundle.Failure.tooLarge(limits.totalBytes) }
        bytes += size
    }
}

extension PasteBundle {
    /// Reader decodes a bundle, validating each header before its bytes are read.
    public struct Reader {
        private let handle: FileHandle
        private var buffer = Data()
        private var counter: LimitCounter
        private var started = false
        private var seen: Set<String> = []
        private var rootNames: [String] = []
        private var rootIsFolder = false
        private var pending: Int64 = 0

        public init(handle: FileHandle, limits: Limits = .standard) {
            self.handle = handle
            self.counter = LimitCounter(limits: limits)
        }

        /// next returns the next validated header, nil at the clean end of the bundle. The previous entry's body
        /// must have been consumed with `copyBody` first.
        public mutating func next() throws -> Header? {
            if !started {
                guard try readLine() == Data(versionLine.utf8) else { throw Failure.unsupportedVersion }
                started = true
            }
            guard pending == 0 else { throw Failure.truncated }
            guard let line = try readLine() else {
                guard !rootNames.isEmpty else { throw Failure.empty }
                return nil
            }
            guard let header = try? JSONDecoder().decode(Header.self, from: line) else { throw Failure.malformedHeader }
            try validate(header)
            pending = header.kind == .file ? header.size : 0
            return header
        }

        /// copyBody writes the current file entry's bytes to `fd`.
        public mutating func copyBody(to fd: Int32) throws {
            let out = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            while pending > 0 {
                let chunk = try read(max: Int(min(pending, Int64(chunkBytes))))
                guard !chunk.isEmpty else { throw Failure.truncated }
                try out.write(contentsOf: chunk)
                pending -= Int64(chunk.count)
            }
        }

        private mutating func validate(_ header: Header) throws {
            let parts = header.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.allSatisfy(isSafeComponent) else { throw Failure.badPath(header.path) }
            switch header.root {
            case rootNames.count:
                guard parts.count == 1 else { throw Failure.badPath(header.path) }
                rootNames.append(parts[0])
                rootIsFolder = header.kind == .dir
            case rootNames.count - 1:
                guard rootIsFolder, parts.count > 1, parts[0] == rootNames[header.root] else { throw Failure.badPath(header.path) }
            default:
                throw Failure.malformedHeader
            }
            guard seen.insert("\(header.root)/\(header.path)").inserted else { throw Failure.duplicate(header.path) }
            guard header.kind == .file || header.size == 0 else { throw Failure.malformedHeader }
            try counter.add(header.size)
        }

        private mutating func readLine() throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard line.count <= maxHeaderBytes else { throw Failure.headerTooLong }
                    return Data(line)
                }
                guard buffer.count <= maxHeaderBytes else { throw Failure.headerTooLong }
                guard let more = try handle.read(upToCount: chunkBytes), !more.isEmpty else {
                    guard buffer.isEmpty else { throw Failure.truncated }
                    return nil
                }
                buffer.append(more)
            }
        }

        private mutating func read(max: Int) throws -> Data {
            if buffer.isEmpty, let more = try handle.read(upToCount: chunkBytes) { buffer = more }
            let chunk = buffer.prefix(max)
            buffer.removeFirst(chunk.count)
            return Data(chunk)
        }
    }
}
