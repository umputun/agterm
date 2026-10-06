import Foundation
import Observation
import agtermCore

/// RemotesWatcher re-reads `remotes.conf` into `entries` when the file or its directory changes.
@MainActor
@Observable
final class RemotesWatcher {
    private(set) var entries: [RemoteEntry] = []
    /// issueCount is how many problems the file has: its parse diagnostics, or one when it cannot be read.
    private(set) var issueCount = 0
    @ObservationIgnored private var url: URL
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private let onIssues: (Int) -> Void

    /// `onIssues` runs when an edit turns a clean file into one with problems, once per such episode.
    init(url: URL, onIssues: @escaping (Int) -> Void = { _ in }) {
        self.url = url
        self.onIssues = onIssues
        refresh(reporting: false)
    }

    isolated deinit {
        sources.forEach { $0.cancel() }
    }

    /// watch switches to another file, as a config directory change does.
    func watch(_ url: URL) {
        self.url = url
        refresh(reporting: false)
    }

    /// refresh re-arms on every event: an editor that saves by replacing the file leaves the old descriptor
    /// on a file nothing names any more, and a directory created later is only visible from its parent.
    private func refresh(reporting: Bool) {
        let loaded = try? RemotesFile.load(at: url)
        let entries = loaded?.remotes.entries ?? []
        if entries != self.entries { self.entries = entries }
        let issues = loaded?.diagnostics.count ?? 1
        let turnedBad = issueCount == 0 && issues > 0
        if issues != issueCount { issueCount = issues }
        if reporting, turnedBad { onIssues(issues) }
        sources.forEach { $0.cancel() }
        sources = watchedPaths().compactMap(source)
    }

    /// watchedPaths includes a symlink target's directory, so a target recreated later is observed.
    private func watchedPaths() -> [String] {
        var paths = [url.path, Self.nearestExistingDirectory(of: url)]
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
            let directory = Self.nearestExistingDirectory(of: target.standardizedFileURL)
            if !paths.contains(directory) { paths.append(directory) }
        }
        return paths
    }

    private func source(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh(reporting: true) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private static func nearestExistingDirectory(of url: URL) -> String {
        var directory = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory = directory.deletingLastPathComponent()
        }
        return directory.path
    }
}
