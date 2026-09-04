import agtermCore
import AppKit
import Foundation

/// Diagnostic-only trace for issue #539, appended to `<stateDir>/split-trace.log`. This file exists on the
/// `539-trace` branch alone and is never merged: it answers which of three reveal-time layout paths runs on
/// a machine where the restored top/bottom split overlaps the titlebar.
enum SplitTrace {
    private static let started = Date()
    private static let lock = NSLock()

    static let url: URL = {
        let base = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PersistenceStore.defaultDirectory
        return base.appendingPathComponent("split-trace.log")
    }()

    /// Append one keyed line, prefixed with seconds since the first trace call.
    static func log(_ fields: [String]) {
        let line = String(format: "t=%.3f ", Date().timeIntervalSince(started))
            + fields.joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// `Class(x,y,w,h,nl=0|1)` for one view, `nil` when absent.
    static func describe(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        let frame = view.frame
        return String(format: "%@(%.1f,%.1f,%.1f,%.1f,nl=%d)",
                      String(describing: type(of: view)), frame.origin.x, frame.origin.y,
                      frame.width, frame.height, view.needsLayout ? 1 : 0)
    }
}
