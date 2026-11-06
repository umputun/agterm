import Foundation

/// BoundedFile reads a file named by untrusted output through one descriptor and judges what that descriptor
/// names: a symlink is measured at its target, and a FIFO, device, offloaded iCloud placeholder or file over
/// the caller's cap is refused before a byte is read.
public enum BoundedFile {
    public enum Failure: Error, Sendable, Equatable {
        case unreadable
        case tooLarge
    }

    /// FileStamp names one version of a file: a change of inode means it was replaced, of size or mtime that it
    /// was written.
    public struct FileStamp: Sendable, Equatable {
        public let device: UInt64
        public let inode: UInt64
        public let size: Int
        public let modifiedSeconds: Int
        public let modifiedNanoseconds: Int

        public init(device: UInt64, inode: UInt64, size: Int, modifiedSeconds: Int, modifiedNanoseconds: Int) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modifiedSeconds = modifiedSeconds
            self.modifiedNanoseconds = modifiedNanoseconds
        }
    }

    /// TailRead is the end of a file: its bytes, the file offset they start at, and its stamp.
    public struct TailRead: Sendable, Equatable {
        public let data: Data
        public let offset: Int
        public let stamp: FileStamp
    }

    /// check opens `path` and judges it without reading, for a caller deciding only whether a page can open.
    public static func check(path: String, maxBytes: Int) -> Result<Void, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { _, _ in .success(()) }
    }

    /// read returns the whole regular file at `path`, through the one descriptor it checked.
    public static func read(path: String, maxBytes: Int) -> Result<Data, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { fd, info in
            readFully(fd, offset: 0, count: Int(info.st_size)).map(Result.success) ?? .failure(.unreadable)
        }
    }

    /// readTail returns the last `maxBytes` of the regular file at `path` plus the byte before them, which tells
    /// `LogTail` whether the window opens on a line boundary. Any size is accepted. nil when the file still has
    /// `unchangedFrom`'s stamp: nothing is read then.
    public static func readTail(path: String, maxBytes: Int, unchangedFrom: FileStamp? = nil) -> Result<TailRead?, Failure> {
        withDescriptor(path: path, maxBytes: nil) { fd, info in
            let size = Int(info.st_size)
            #if canImport(Darwin)
            let modified = info.st_mtimespec
            #else
            let modified = info.st_mtim
            #endif
            let stamp = FileStamp(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino), size: size,
                                  modifiedSeconds: Int(modified.tv_sec), modifiedNanoseconds: Int(modified.tv_nsec))
            if stamp == unchangedFrom { return .success(nil) }
            let offset = max(0, size - maxBytes - 1)
            guard let data = readFully(fd, offset: offset, count: size - offset) else { return .failure(.unreadable) }
            return .success(TailRead(data: data, offset: offset, stamp: stamp))
        }
    }

    // nil when the file ends before `count` bytes, as one being truncated under the read does
    private static func readFully(_ fd: Int32, offset: Int, count: Int) -> Data? {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let read = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + filled, count - filled, off_t(offset + filled))
            }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { break }
            filled += read
        }
        return filled == count ? data : nil
    }

    private static func withDescriptor<T>(path: String, maxBytes: Int?,
                                          _ body: (Int32, stat) -> Result<T, Failure>) -> Result<T, Failure> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !isPlaceholder(info) else {
            return .failure(.unreadable)
        }
        if let maxBytes, info.st_size > maxBytes { return .failure(.tooLarge) }
        return body(fd, info)
    }

    private static func isPlaceholder(_ info: stat) -> Bool {
        #if canImport(Darwin)
        info.st_flags & UInt32(SF_DATALESS) != 0
        #else
        false
        #endif
    }
}
