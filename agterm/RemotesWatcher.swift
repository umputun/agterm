import Foundation
import Observation
import agtermCore

/// RemotesWatcher re-reads `remotes.conf` into `entries` when the file or its directory changes.
@MainActor
@Observable
final class RemotesWatcher {
    private(set) var entries: [RemoteEntry] = []
    @ObservationIgnored private var url: URL
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []

    init(url: URL) {
        self.url = url
        refresh()
    }

    isolated deinit {
        sources.forEach { $0.cancel() }
    }

    /// watch switches to another file, as a config directory change does.
    func watch(_ url: URL) {
        self.url = url
        refresh()
    }

    /// refresh re-arms on every event: an editor that saves by replacing the file leaves the old descriptor
    /// on a file nothing names any more, and a directory created later is only visible from its parent.
    private func refresh() {
        let loaded = (try? RemotesFile.load(at: url).remotes.entries) ?? []
        if loaded != entries { entries = loaded }
        sources.forEach { $0.cancel() }
        sources = [url.path, Self.nearestExistingDirectory(of: url)].compactMap(source)
    }

    private func source(for path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
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
