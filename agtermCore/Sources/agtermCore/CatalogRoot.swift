import Foundation

/// CatalogRoot is the logical window a headless store answers as: one durable id per server state directory and
/// a display name. It stands where a Mac window's id and name stand on the wire, so `zmx tree` sessions carry it
/// as `windowID`/`windowName` and a Mac binds its remote window to the id.
public struct CatalogRoot: Sendable, Equatable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .unreadable(let path): "catalog id cannot be read: \(path)"
            case .malformed(let path): "catalog id is not a UUID: \(path)"
            }
        }
    }

    static let filename = "catalog-id"

    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    /// load reads the catalog id from `directory`, writing a new one only when the file does not exist. A file
    /// that cannot be read or holds anything else throws and is left alone: a new id would make every Mac bound
    /// to this server see a different catalog.
    public static func load(directory: URL, name: String) throws -> CatalogRoot {
        let file = directory.appendingPathComponent(filename)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            let id = UUID()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(id.uuidString)\n".utf8).write(to: file, options: .atomic)
            return CatalogRoot(id: id, name: name)
        } catch {
            throw Failure.unreadable(file.path)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: text) else { throw Failure.malformed(file.path) }
        return CatalogRoot(id: id, name: name)
    }

    /// projection presents the store's tree as this catalog's one window.
    public func projection(of tree: ControlTree) -> RemoteWindowProjection {
        RemoteWindowProjection(id: id.uuidString, name: name, tree: tree)
    }

    /// seedWorkspace gives an empty store its first workspace and leaves any existing one, renamed or not, alone.
    @MainActor
    public static func seedWorkspace(in store: AppStore) {
        guard store.workspaces.isEmpty else { return }
        _ = store.addWorkspace(name: store.defaultWorkspaceName)
    }
}

/// HeadlessCommandPolicy names the commands a headless origin refuses because they drive a Mac window or the Mac
/// app itself. It is not the server's whole support list: the server refuses anything it does not serve by
/// default, and this gives these commands a reason the caller can act on.
public enum HeadlessCommandPolicy {
    static let physicalWindowCommands: Set<Command> = [
        .windowNew, .windowSelect, .windowGo, .windowClose, .windowRename, .windowDelete, .windowResize,
        .windowMove, .windowZoom, .windowFullscreen, .windowMinimize, .windowRemoteOpen,
        .sidebar, .sidebarMode, .sidebarFlaggedLayout, .sidebarDensity, .sidebarExpand, .sidebarCollapse,
        .sidebarWidth, .fontInc, .fontDec, .fontReset, .quick, .quickType, .quickText, .dashboard,
        .surfaceZoom, .surfaceCursor, .themeSet, .themeList, .keymapReload, .keymapList, .keymapRun,
        .configReload, .browserClear, .browserLinks,
    ]

    /// physicalWindowRefusal is the error for a command that only a Mac window can carry out, nil for any other.
    public static func physicalWindowRefusal(_ command: Command) -> String? {
        guard physicalWindowCommands.contains(command) else { return nil }
        return "\(command.rawValue) is not available on agterm-server: it drives a window on the Mac showing it"
    }
}
