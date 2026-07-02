import Foundation
import agtermCore

/// The control channel's target-resolution query layer. Owns the `emptyStore` frontmost-fallback and the
/// `store` accessor, and wraps agtermCore's pure `ControlResolve` string matcher with app-side store
/// scoping plus the pinned wire-error formatting the CLI/tests depend on — it does not duplicate the matcher.
@MainActor
final class ControlTargetResolver {
    /// The window library the resolver scopes stores against (frontmost default, cross-window id/prefix).
    private let library: WindowLibrary

    /// The frontmost open window's store — the default target of a placement/`active` command. Falls
    /// back to an empty throwaway only in the all-windows-closed state (the app is quitting), where no
    /// command can meaningfully run; the library is never windowless at launch.
    private lazy var emptyStore = AppStore()
    private var store: AppStore { library.activeStore ?? emptyStore }

    init(library: WindowLibrary) {
        self.library = library
    }

    // MARK: - Window resolution & cross-window targeting

    /// A resolution outcome carrying either the resolved value or the structured error response to
    /// return. (`ControlResponse` isn't an `Error`, so this stands in for `Result` with the same case
    /// names.)
    enum Resolution<T> {
        case success(T)
        case failure(ControlResponse)
    }

    /// The open store a placement/`active` command targets: with `window` set, the resolved open
    /// window's store (an error response when it isn't open / can't be resolved); without it, the
    /// frontmost window's store. Runs `body` with that store on success.
    func resolvePlacementStore(_ window: String?, _ body: (AppStore) -> ControlResponse) -> ControlResponse {
        switch resolveWindowStore(window) {
        case .failure(let response): return response
        case .success(let store): return body(store)
        }
    }

    /// Resolve `window` to an OPEN window's store. nil → the frontmost store. A set value resolves the
    /// window id (active=frontmost / exact / prefix / ambiguous / not-found); the window must be open,
    /// else the closed-window error.
    private func resolveWindowStore(_ window: String?) -> Resolution<AppStore> {
        guard let window = trimmed(window) else { return .success(store) }
        let resolution = ControlResolve.resolve(window, candidates: library.windows.map(\.id), active: library.activeWindowID)
        guard case .resolved(let id) = resolution else {
            return .failure(resolutionError("window", target: window, resolution))
        }
        guard let store = library.store(for: id) else {
            return .failure(ControlResponse(ok: false, error: "window not open — window.select it first"))
        }
        return .success(store)
    }

    // MARK: - Session / workspace target resolution

    /// Resolve `target` (defaulting to `active`) to a session and its owning store, then run `body`.
    /// With `window` set, the search is scoped to that open window's store; without it, `active`
    /// resolves against the frontmost store while an id/prefix is matched across ALL open stores so a
    /// captured id resolves regardless of which window is frontmost.
    func resolveSession(_ target: String?, window: String?,
                        _ body: (AppStore, UUID) -> ControlResponse) -> ControlResponse {
        switch resolveSessionTarget(target, window: window) {
        case .failure(let response): return response
        case .success(let (store, id)): return body(store, id)
        }
    }

    /// Resolve `target` (defaulting to `active`) to a workspace and its owning store, then run `body`.
    /// Same windowed/cross-window rules as `resolveSession`.
    func resolveWorkspace(_ target: String?, window: String?,
                          _ body: (AppStore, UUID) -> ControlResponse) -> ControlResponse {
        switch resolveWindowStore(window) {
        case .failure(let response):
            return response
        case .success(let scoped):
            // a window was named, or `active`/placement defaults to the frontmost store.
            if trimmed(window) != nil || (target ?? "active") == "active" {
                return resolve(target ?? "active", candidates: scoped.workspaces.map(\.id),
                               active: scoped.currentWorkspaceID, noun: "workspace") { id in
                    body(scoped, id)
                }
            }
            // no window arg + an id/prefix: match across all open stores, mapping back to the owner.
            return resolveAcrossWindows(target ?? "active", noun: "workspace",
                                        candidates: { $0.workspaces.map(\.id) }, body)
        }
    }

    /// The session target as a `(store, id)` result, used by both `resolveSession` and the async
    /// `session.type` path. See `resolveSession` for the windowed/cross-window rules.
    func resolveSessionTarget(_ target: String?, window: String?) -> Resolution<(AppStore, UUID)> {
        switch resolveWindowStore(window) {
        case .failure(let response):
            return .failure(response)
        case .success(let scoped):
            if trimmed(window) != nil || (target ?? "active") == "active" {
                let target = target ?? "active"
                let resolution = ControlResolve.resolve(target, candidates: scoped.workspaces.flatMap { $0.sessions.map(\.id) },
                                                         active: scoped.selectedSessionID)
                guard case .resolved(let id) = resolution else {
                    return .failure(resolutionError("session", target: target, resolution))
                }
                return .success((scoped, id))
            }
            return resolveTargetAcrossWindows(target ?? "active", noun: "session",
                                              candidates: { $0.workspaces.flatMap { $0.sessions.map(\.id) } })
        }
    }

    /// Match an id/prefix `target` against the gathered candidates of EVERY open window's store,
    /// returning the resolved id and its owning store, or a structured error.
    private func resolveTargetAcrossWindows(_ target: String, noun: String,
                                            candidates: (AppStore) -> [UUID]) -> Resolution<(AppStore, UUID)> {
        let stores = library.openIDs().compactMap { library.store(for: $0) }
        let all = stores.flatMap(candidates)
        let resolution = ControlResolve.resolve(target, candidates: all, active: nil)
        guard case .resolved(let id) = resolution,
              let owner = stores.first(where: { candidates($0).contains(id) }) else {
            return .failure(resolutionError(noun, target: target, resolution))
        }
        return .success((owner, id))
    }

    /// `resolveTargetAcrossWindows` adapted to the `(store, id) -> ControlResponse` body shape.
    private func resolveAcrossWindows(_ target: String, noun: String, candidates: (AppStore) -> [UUID],
                                      _ body: (AppStore, UUID) -> ControlResponse) -> ControlResponse {
        switch resolveTargetAcrossWindows(target, noun: noun, candidates: candidates) {
        case .failure(let response): return response
        case .success(let (store, id)): return body(store, id)
        }
    }

    func resolve(_ target: String, candidates: [UUID], active: UUID?, noun: String,
                 _ body: (UUID) -> ControlResponse) -> ControlResponse {
        let resolution = ControlResolve.resolve(target, candidates: candidates, active: active)
        if case .resolved(let id) = resolution { return body(id) }
        return resolutionError(noun, target: target, resolution)
    }

    /// The structured error response for a non-`.resolved` resolution (the single source of the wire
    /// "no such <noun>: …" / "ambiguous <noun> prefix '…' → <prefix8 list>" strings, which tests pin).
    /// `.resolved` maps to the not-found string too, covering the across-windows owner-lookup miss.
    private func resolutionError(_ noun: String, target: String, _ resolution: TargetResolution) -> ControlResponse {
        let message = ControlResolve.errorMessage(noun: noun, target: target, resolution: resolution)
        return ControlResponse(ok: false, error: message)
    }

    /// Resolve a window `target` (defaulting to `active` = frontmost) to a window id, or the structured
    /// error. Unlike the session/workspace resolvers, a window need not be open to be a target (select
    /// opens it, delete removes a closed one).
    func resolveWindowID(_ target: String?) -> Resolution<UUID> {
        let resolution = ControlResolve.resolve(target ?? "active", candidates: library.windows.map(\.id),
                                                active: library.activeWindowID)
        guard case .resolved(let id) = resolution else {
            return .failure(resolutionError("window", target: target ?? "active", resolution))
        }
        return .success(id)
    }

    /// `resolveWindowID` adapted to the callback body shape (rename/delete, which act synchronously).
    func resolveWindowID(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        switch resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id): return body(id)
        }
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
