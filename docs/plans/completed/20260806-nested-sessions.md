# Nested (child) sessions

> **For agentic workers:** implement task-by-task, host-free `agtermCore` first. Every task ends green:
> `cd agtermCore && swift test`, `make build`, `make test-app` where relevant, and `make lint`
> (`swiftlint --strict`, zero findings) all pass before the next task starts. Steps use `- [x]` checkboxes.
> This project's maintainer commits — do NOT run `git commit`/`git add`.

## Overview

Let a session be created **as a child of another session** and rendered as an indented sub-tree under its
parent in the sidebar, at arbitrary depth. The headline case is agent-driven: a skill running inside a
session spawns a helper session and stacks it under the caller
(`agtermctl session new --parent "$AGTERM_SESSION_ID"`, or `--parent active`), so related work groups
visually instead of scattering as flat siblings.

- **Problem:** every session today is a flat leaf under its workspace. A skill that spawns N helper
  sessions produces N ungrouped rows with no visible parent/child relationship.
- **Solution:** an **adjacency-list** model — one new `Session.parentID: UUID?` (nil = top-level = today).
  `Workspace.sessions` stays a **flat ordered array**; the parent→child tree is *derived* for display.
  The confining invariant is **contiguity**: a parent is immediately followed by its whole subtree
  (depth-first preorder), so **array order == visual tree order** and every subtree is a contiguous block.
  This keeps every existing flat consumer (navigation, flagged view, focus filter, persistence, recency,
  reorder) working unchanged, and confines the real change to the sidebar tree-build plus a few
  block-move operations.
- **Why adjacency, not `Session.children: [Session]`:** nested storage forces navigation, flagged view,
  focus, persistence, recency, and close to all recurse — the opposite of the maintainer's "minimal,
  clean, structural" bar. Adjacency adds one optional field and one invariant.
- **Close semantics (decided):** closing a parent **cascades** — its whole subtree closes together, with a
  confirm showing the descendant count and one grouped grace-undo / Reopen record. This reuses the exact
  pattern `removeWorkspace` already uses for a workspace full of sessions (see `AppStore.removeWorkspace`,
  `AppStore.swift:475`), so it is not new machinery.
- **Parenting surface (decided): creation-time AND drag-to-reparent.**
  - Create: `session.new --parent <sid|active>` and a sidebar **New Child Session** context item.
    `--after`/`--before` **inherit the anchor's `parentID`**, so `session new --after active` from inside a
    child session creates a *sibling child* — the agent idiom keeps working at any depth.
  - Reparent: drop a session onto another in the sidebar (child), or drag it out to top-level; plus control
    parity via `session move --parent <sid>` / `session move --unparent`.
- **Maintainer approval:** the use case is pre-approved (this reverses the general "no extra tree depth"
  stance in [discussion #293](https://github.com/umputun/agterm/discussions/293) specifically for
  agent-spawned session grouping). The bar is a top-notch, minimal, structural implementation.

### Prior art reused (do NOT reinvent)

- **`docs/plans/completed/20260705-session-placement-flags.md`** — the `--after`/`--before` feature is the
  near-exact template: optional field on `ControlArgs` + `ControlSessionCreateOptions`, a
  `ControlSessionMove` case, `SidebarDrop.resolveRelative` + `AppStore.addSession(at:)`, dispatcher
  mutual-exclusion guards, and the test harnesses (`ControlProtocolTests`, `SidebarDropTests`,
  `ControlDispatcherTests`, `agtermctlKitTests/CommandsTests`, `ControlAPIUITests` with
  `relaunch(withSnapshot:)` / `pollSessionOrder` / `pollSessionCounts`).
- **`docs/plans/completed/20260626-sidebar-flagged-and-focus.md`** — how the outline data source
  (`numberOfChildrenOfItem`/`child`/`isItemExpandable`) and the `TreeShape`/`RowContent` reconcile split
  were extended for a second rendering shape. Nesting extends the same three methods + `TreeShape`.
- **`docs/plans/completed/20260621-session-navigation.md`** — `WorkspaceSidebar.syncSelection()` already
  expands a collapsed owner workspace and `scrollRowToVisible`s a selected off-screen row
  (`expandItem(owner)`); generalize from workspace-owner to the full ancestor chain.

## Context (from discovery — exact hook points)

Host-free model / persistence (`agtermCore`):
- `Session.swift:82` — `Session` fields + `init(id:initialCwd:customName:)` at `:370`.
- `Workspace.swift:6` — `Workspace { id, name, sessions: [Session], isExpanded }`; the `isExpanded` pattern
  to mirror for sessions.
- `Snapshot.swift` — `SessionSnapshot` (fields `:139-175`, `CodingKeys` `:200-204`, memberwise init
  `:177-198`, custom `init(from:)` `:213-230`, all non-key fields lossy `(try? decodeIfPresent) ?? nil`);
  `WorkspaceSnapshot` (`collapsed: Bool?` is the inverse of `isExpanded`, `:105-134`);
  `Snapshot.currentVersion = 1` (`:12`) — **not bumped** (new fields are optional).
- `AppStore+Snapshot.swift:30` `sessionSnapshot(_:)` (capture), `:62` `session(from:launchRestore:)`
  (restore), `:13` `snapshot()` (workspace `collapsed: isExpanded ? nil : true`).
- `AppStore.swift:368` `addSession(...at:select:)`; `:441` `closeSession(_:)`; `:475` `removeWorkspace(_:)`
  (the cascade-teardown precedent); `:515` `moveSession(_:toWorkspace:at:)`; `:700` `setWorkspaceExpanded`;
  `:709` `setWorkspacesExpanded`; `sessionLocation(ofSession:)` (returns `(workspace, index, count)`);
  `session(withID:)`.
- `AppStore+PendingClose.swift:58` `softCloseSession(_:grace:)`, `:102` `softCloseSessions(_:grace:)`
  (grouped grace-undo — the cascade-close vehicle); `AppStore+RecentClosed.swift` (undo records).
- `AppStore+Events.swift:22` `emitSessionCreated(_:workspace:)` → `ControlEventPayload(name:)`
  (`ControlEvents.swift:14`).
- `SidebarDrop.swift` — `resolveSession`, `resolveSessions` (batch block move), `resolveRelative` (the
  anchor→index reuse). Extend with subtree-block awareness + a cycle guard.

Control (host-free protocol + app effects):
- `ControlProtocol.swift:10` `sessionNew`, `:17` `sessionMove`; `ControlSessionNode` (`:458-557`, synthesized
  Codable, optional lets omit nil).
- `ControlModes.swift:126` `ControlSessionCreateOptions`; `:111` `ControlSessionMove` enum;
  `ControlArgs` (in `ControlProtocol.swift`, carries `after`/`before`/`to`/`workspace`/`targets`).
- `ControlDispatcher.swift:10/22-23` `ControlActions.createSession`/`moveSession`/`moveSessions`;
  `.sessionNew` arm `:244-275`; `.sessionMove` arm `:302-341`; `dispatchSessionMove` `:447`.
- `agterm/Control/ControlServer+SessionActions.swift:124` `createSession`, `:162` `resolveAnchorLocation`;
  `agterm/Control/ControlServer.swift:557` `makeSessionResponse(in:workspaceID:options:at:)`;
  `moveSession`/`placeSession` in the same file (`:482-568`).
- `agtermctlKit/SessionCommands.swift:26` `struct New`, `:136` `struct Move`.

App-side sidebar (AppKit `NSOutlineView`):
- `Views/WorkspaceSidebar.swift:116` `Coordinator`; data source `:709-722`
  (`numberOfChildrenOfItem`/`child`/`isItemExpandable`); expand/collapse delegates `:580-595`;
  `expandedWorkspaceIDs` `:140`, `suppressExpansionPersist` `:145`; `reconcile()` `:374`,
  `currentShape()` `:391`, `TreeShape` `:335`, `RowContent` `:343`; `rebuildAndReload()` `:450`
  (SidebarNode build + expansion re-apply `:485-501`); `syncSelection()` `:608` (collapsed-owner reveal).
- `Views/SidebarRowViews.swift:268` `SidebarNode { enum Kind { case workspace, session }; id; children }`.
- `Views/WorkspaceSidebar+RowRendering.swift` — cell builder (`:28`), `iconForSession` (`:97`),
  `applyBadge` (`:90`), `rowLabel(forSession:)` (`:220`).
- `Views/WorkspaceSidebar+ContextMenu.swift:266` `addSession(toWorkspace:cwd:)`, row menu `:131`,
  inline "+" `:228`; `Views/WorkspaceSidebar+DragDrop.swift` (drop validate/accept).
- `AppActions.swift:117` `newSession()`; `agtermApp+Menus.swift` (session menu items).

Environment (already present — the parent handle a skill passes):
- `SurfaceEnvironment.swift:17` injects `AGTERM_SESSION_ID`, `:24` `AGTERM_WORKSPACE_ID` into every shell.

Docs / keep-in-sync:
- `plugins/agterm/skills/agterm/` (`SKILL.md` "Command summary (74 commands)" `:151`, `reference.md`,
  `examples.md`, `troubleshooting.md`); `.claude/rules/sidebar.md`, `control-api.md`; `README.md:187`
  ("74 commands"); `site/docs.html`, `site/commands.html` (count on `:9,21,33,240`), `site/index.html`.

## Global constraints (HARD — verify against every task)

- **`agtermCore` stays host-free:** no `import GhosttyKit`/`AppKit`/`Metal`/CoreGraphics (no
  `CGSize`/`CGPoint`/`CGRect`/`CGFloat`). Pure model / index math / dispatcher / CLI parse live here; the
  app target is the thin side-effect adapter.
- **Backward compatible, no version bump:** `Session.parentID`/`isExpanded` snapshot fields are OPTIONAL;
  a legacy `workspaces.json` / `windows/<id>.json` must decode with every session top-level and expanded,
  and a non-nested tree must serialize byte-identically to today (emit `parentID`/`collapsed` only when
  non-default). `Snapshot.currentVersion` stays `1`.
- **Contiguity invariant (load-bearing):** within one `Workspace.sessions` array, a parent is immediately
  followed by its entire subtree in depth-first preorder. Every structural op (create-child, reparent,
  reorder, cross-workspace move, cascade close) preserves it. Same-workspace parent only — a child and its
  parent always live in one workspace.
- **No cycles:** a session may not be reparented under itself or any of its descendants.
- **Green tree after every task:** `swift test`, `make build`, `make test-app` (when app code changed),
  `make lint --strict` all clean.
- **File sizes:** source < 1000 lines, tests < 2000. New pure logic goes in NEW files (`SessionTree.swift`)
  rather than growing `AppStore.swift`/`Session.swift`; if a touched file nears the limit, stop and ask —
  never bump the swiftlint limit.
- **Cross-surface contract:** a new user-facing action isn't done until it is drivable from the control
  socket with dispatcher + CLI + round-trip/e2e tests, and the bundled skill + rules + README + site are
  updated. State-setting commands expose read-back on `ControlSessionNode`.
- **`CHANGELOG.md` is release-only — do NOT touch it here.**
- **Protect the live terminal:** all manual verification uses a separate `open -n` Debug instance with an
  isolated `AGTERM_STATE_DIR` + short socket; never drive the default socket, never quit/relaunch the
  deployed app.

## Development approach

- **Testing: regular (code first, then tests in the SAME task)** — the maintainer's chosen cadence; every
  code task lists its tests as explicit checklist items and they pass before the next task starts.
- Bottom-up: host-free model + tree math + AppStore ops (unit-tested with `swift test`) → control protocol
  + dispatcher + CLI → app-side effects + read-back → sidebar rendering → drag-reparent → GUI affordances →
  docs → verify.
- Small, focused changes; keep this plan in sync (`➕` new task, `⚠️` blocker) if scope shifts.

## Open decision (confirm at review)

**Task 10 — `session.collapse`/`session.expand` control commands** for folding a parent session's subtree.
Collapsing a parent IS a new user action, and the CLAUDE.md control-parity contract plus the exact
`workspace.collapse`/`.expand` precedent argue it should be control-drivable (74 → 76 commands). The
minimal alternative is GUI-only collapse with `tree` read-back (`ControlSessionNode.collapsed`) and no new
command (stays 74). This plan **includes** Task 10 by default as the consistent choice; the reviewer may
cut it, in which case the command-count doc bumps in Task 11 are dropped and `collapsed` stays a read-back
of a GUI-only toggle.

---

## Implementation Steps

### Task 1: Model + persistence fields (`agtermCore`)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (fields near `:119`; init `:370`)
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift` (`SessionSnapshot` `:138-231`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Snapshot.swift` (`sessionSnapshot` `:30`, `session(from:)` `:62`)
- Test: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift`

**Interfaces produced:**
- `Session.parentID: UUID?` (observed, default nil), `Session.isExpanded: Bool` (observed, default true).
- `SessionSnapshot.parentID: UUID?`, `SessionSnapshot.collapsed: Bool?` (inverse of `isExpanded`).

- [x] `Session.swift`: add `public var parentID: UUID?` and `public var isExpanded: Bool = true` beside
      `flagged` (`:119`); both observed (NOT `@ObservationIgnored`) so a reparent / collapse reloads the
      sidebar. Do NOT add them to `init` params (set post-construction like `initialCommand`).
- [x] `Snapshot.swift`: add `public var parentID: UUID?` and `public var collapsed: Bool?` to
      `SessionSnapshot`; extend the memberwise `init` (both defaulting nil, appended after
      `splitRestoreCommand` to keep call-site diffs minimal), the `CodingKeys` enum (`case parentID,
      collapsed`), and the custom `init(from:)` with the same lossy pattern:
      `parentID = (try? c.decodeIfPresent(UUID.self, forKey: .parentID)) ?? nil` and likewise `collapsed`.
      No `encode(to:)` (synthesized `encodeIfPresent` omits nil). Do NOT bump `currentVersion`.
- [x] `AppStore+Snapshot.swift` `sessionSnapshot(_:)`: pass `parentID: session.parentID` and
      `collapsed: session.isExpanded ? nil : true` (emit `collapsed` only when collapsed, mirroring the
      workspace rule, so a non-collapsed session stays byte-identical).
- [x] `AppStore+Snapshot.swift` `session(from:launchRestore:)`: set `session.parentID = snapshot.parentID`
      and `session.isExpanded = !(snapshot.collapsed ?? false)`.
- [x] Tests (`PersistenceTests`): round-trip a session with `parentID` set + `collapsed` true; round-trip
      with both unset; decode a legacy `SessionSnapshot` JSON literal WITHOUT the keys → `parentID == nil`,
      `isExpanded == true`; assert a non-nested/expanded tree encodes without `parentID`/`collapsed` keys
      (byte-compat — encode and grep the JSON for absence).
- [x] `cd agtermCore && swift test` — green before Task 2.

### Task 2: Host-free tree math — `SessionTree` (`agtermCore`)

**Files:**
- Create: `agtermCore/Sources/agtermCore/SessionTree.swift`
- Create: `agtermCore/Tests/agtermCoreTests/SessionTreeTests.swift`

**Interfaces produced** (all pure, operate on a flat ordered `[Node]` obeying the contiguity invariant;
`Node = (id: UUID, parentID: UUID?)` so it is testable without `Session`/`@MainActor`):
```swift
public enum SessionTree {
    public struct Node: Equatable, Sendable { public let id: UUID; public let parentID: UUID?
        public init(id: UUID, parentID: UUID?) }
    /// Half-open index range of `parentID`'s node plus its entire subtree (the contiguous block),
    /// or nil if the id is absent. The block starts at the node itself.
    public static func subtreeRange(of id: UUID, in order: [Node]) -> Range<Int>?
    /// Ids of every descendant of `id` (excludes `id`), in tree order.
    public static func descendantIDs(of id: UUID, in order: [Node]) -> [UUID]
    /// True if `candidate` is `ancestor` or a descendant of it — the reparent cycle guard.
    public static func isSelfOrDescendant(_ candidate: UUID, of ancestor: UUID, in order: [Node]) -> Bool
    /// The array index just past the last element of `parentID`'s subtree — the insert slot for a new
    /// last-child. For a nil parent (top-level append) returns `order.count`.
    public static func appendChildIndex(parent: UUID?, in order: [Node]) -> Int
    /// The chain of ancestor ids from the direct parent up to the root (nearest first), for expand-reveal.
    public static func ancestorIDs(of id: UUID, in order: [Node]) -> [UUID]
    /// Reorders `order` into canonical depth-first preorder given each node's parentID, preserving the
    /// existing relative order of siblings. Used to REPAIR contiguity after a reparent/move builds the
    /// new parentID set; returns ids in the corrected order. Roots keep their current relative order.
    public static func preorder(_ order: [Node]) -> [UUID]
}
```

- [x] Implement `SessionTree` with the signatures above. `subtreeRange`: find the node's index `i`, then
      walk forward while the running set of "ids seen inside the block" contains each node's `parentID`
      (i.e. it is a descendant), stopping at the first node whose parentID is outside the block — correct
      because the invariant guarantees contiguity. `isSelfOrDescendant`: `candidate == ancestor ||
      descendantIDs(of: ancestor).contains(candidate)`. `preorder`: build children-by-parent buckets
      preserving input order, then DFS from roots (parentID nil, in input order).
- [x] Tests (`SessionTreeTests`, `@Test`/`#expect`): a 3-level fixture `[A, A/b, A/b/c, A/d, E]` — assert
      `subtreeRange(A) == 0..<4`, `subtreeRange(b) == 1..<3`, `descendantIDs(A) == [b,c,d]`,
      `isSelfOrDescendant(c, of: A) == true`, `isSelfOrDescendant(A, of: c) == false`,
      `appendChildIndex(A) == 4`, `appendChildIndex(nil) == 5`, `ancestorIDs(c) == [b, A]`; `preorder` of a
      deliberately-scrambled-but-valid parentID set returns canonical order; empty input → empty results;
      unknown id → nil range / `[]`.
- [x] `cd agtermCore && swift test` — green before Task 3.

### Task 3: `AppStore` operations — create-child, reparent, collapse, subtree move, cascade close (`agtermCore`)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`addSession` `:368`, `moveSession` `:515`,
  `closeSession` `:441`); new extension `agtermCore/Sources/agtermCore/AppStore+Nesting.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift` (cascade subtree in soft close)
- Test: `agtermCore/Tests/agtermCoreTests/AppStoreNestingTests.swift`

**Interfaces consumed:** `SessionTree.*` (Task 2), `SessionSnapshot`/`Session.parentID` (Task 1).
**Interfaces produced:**
```swift
extension AppStore {
    /// Flat `SessionTree.Node`s for a workspace, in array order (bridges Session → pure tree math).
    func sessionNodes(inWorkspace: UUID) -> [SessionTree.Node]
    /// The id + every descendant id, in tree order (for cascade close / confirm count).
    public func sessionSubtreeIDs(_ sessionID: UUID) -> [UUID]
    /// Reparent `sessionID` (and its subtree) under `newParentID` (nil = top-level) within its OWN
    /// workspace, appended as last child, then repaired to preorder. No-ops on unknown id, a cross-workspace
    /// parent, or a cycle. Persists.
    public func reparentSession(_ sessionID: UUID, to newParentID: UUID?)
    /// Collapse/expand a parent session; mirrors setWorkspaceExpanded. No-op on unknown/unchanged. Persists.
    public func setSessionExpanded(_ sessionID: UUID, expanded: Bool)
}
```

- [x] `addSession(...)`: add `parentID: UUID? = nil`. When non-nil, validate the parent exists in
      `workspaceID` (else ignore the parent, append top-level — do NOT fail creation); set
      `session.parentID`; when `at index` is nil, insert at `SessionTree.appendChildIndex(parent: parentID,
      in: sessionNodes(inWorkspace: workspaceID))` instead of appending. An explicit `at index` (from
      `--after`/`--before`) still wins and the caller sets `parentID` to the anchor's parent (Task 5).
- [x] `AppStore+Nesting.swift`: implement `sessionNodes`, `sessionSubtreeIDs` (map `SessionTree.subtreeRange`
      back to ids), `reparentSession` (guard same workspace via `sessionLocation`; guard
      `!SessionTree.isSelfOrDescendant(newParentID, of: sessionID, ...)` when newParentID non-nil; set
      parentID; rebuild the workspace's `sessions` array to `SessionTree.preorder(...)` order; `save()`),
      and `setSessionExpanded` (mirror `setWorkspaceExpanded` `:700`).
- [x] `moveSession(_:toWorkspace:at:)`: when the moved session has descendants, move the whole subtree
      block (use `SessionTree.subtreeRange`) preserving inner order, and — for a cross-workspace move —
      set the moved root's `parentID = nil` (a subtree can't straddle workspaces; descendants keep their
      parentIDs and ride along). Keep the single-session fast path unchanged for a childless session.
- [x] Cascade close: in the GUI/close path, closing a session with descendants closes the subtree. Add the
      subtree expansion at the `softCloseSessions`/`closeSession` call sites (Task 9 GUI wires the confirm);
      here, make `softCloseSessions(_:)` and the hard `closeSession` accept the subtree id list and record
      ONE grouped undo (they already group a batch — feed `sessionSubtreeIDs(id)` in tree order). Ensure a
      promoted/closed parent's children are torn down, not orphaned.
- [x] Tests (`AppStoreNestingTests`, `@MainActor`): create child inserts at last-child slot preserving
      contiguity; nested grandchild; `reparentSession` moves a subtree block and repairs preorder; reparent
      cycle (parent under its own child) is a no-op; cross-workspace parent is a no-op; `moveSession` of a
      parent carries its subtree and nils the root parentID cross-workspace; `sessionSubtreeIDs` returns
      tree order; cascade close removes the whole subtree and a single undo restores it; `setSessionExpanded`
      flips + saves, unknown id no-ops.
- [x] `cd agtermCore && swift test` — green before Task 4.

### Task 4: Control protocol + dispatcher — `--parent` on new/move (`agtermCore`)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`ControlArgs` + `init`)
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift` (`ControlSessionCreateOptions` `:126`,
  `ControlSessionMove` `:111`)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (`.sessionNew` `:244`, `.sessionMove` `:302`)
- Test: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`,
  `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

**Interfaces produced:**
- `ControlArgs.parent: String?`, `ControlArgs.unparent: Bool?`.
- `ControlSessionCreateOptions.parent: String?` (threaded through its `init`).
- `ControlSessionMove.parent(anchor: String?)` — `anchor` nil = unparent to top-level.
- `.place(anchor:after:)` semantics extended: the placed session ADOPTS the anchor's `parentID` (Task 5).

- [x] `ControlProtocol.swift`: add `public var parent: String?` and `public var unparent: Bool?` to
      `ControlArgs` and its `init` (both optional, default nil — keeps existing call sites / old JSON).
- [x] `ControlModes.swift`: add `public let parent: String?` to `ControlSessionCreateOptions` + its `init`
      (default nil); add `case parent(anchor: String?)` to `ControlSessionMove`.
- [x] `.sessionNew` arm: reject `--parent` combined with `--after`/`--before` (single placement intent) and
      with `--workspace`/`--workspace-name` (the parent names the workspace):
      `"session.new takes --parent, --after/--before, or a workspace, not more than one"`. Thread
      `parent: args?.parent` into `ControlSessionCreateOptions`. Leave the existing after/before/workspace
      guards intact.
- [x] `.sessionMove` arm: before the after/before branch, handle `--parent`/`--unparent`: reject both
      together (`"use either --parent or --unparent, not both"`) and either combined with
      `--to`/`--after`/`--before`/workspace (`"session.move takes --parent/--unparent alone"`), then route
      `actions.moveSession(request.target, window:, move: .parent(anchor: args?.unparent == true ? nil :
      args?.parent))` (single target only — reject `targets.count > 1` with `.parent`:
      `"session.move --parent takes a single --target"`).
- [x] Tests: `ControlProtocolTests` round-trip `session.new`/`session.move` carrying `parent`/`unparent`
      (fields survive, others nil); `ControlDispatcherTests` (mock `ControlActions`) assert each new error
      string, and that valid `--parent`/`--unparent` hand the right `ControlSessionMove.parent` /
      `ControlSessionCreateOptions.parent` to the mock.
- [x] `cd agtermCore && swift test` — green before Task 5.

### Task 5: App-side `ControlActions` + tree read-back (`agtermCore` + app)

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (`createSession` `:124`,
  `resolveAnchorLocation` `:162`, `moveSession`)
- Modify: `agterm/Control/ControlServer.swift` (`makeSessionResponse` `:557`; tree builder)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`ControlSessionNode`) + the app-side
  session-node builder that populates it
- Test: `agtermUITests/ControlAPIUITests.swift`

**Interfaces produced:** `ControlSessionNode.parentID: String?`, `ControlSessionNode.collapsed: Bool?`
(both omitted when nil/expanded).

- [x] `ControlProtocol.swift`: add `public let parentID: String?` and `public let collapsed: Bool?` to
      `ControlSessionNode` + its memberwise init (synthesized Codable already omits nil).
- [x] The session-node builder (where `ControlSessionNode(...)` is constructed for `tree`): set
      `parentID: session.parentID?.uuidString` and `collapsed: session.isExpanded ? nil : true`.
- [x] `resolveAnchorLocation` (`:162`): also surface the anchor session's `parentID` to callers — change its
      `body` tuple to `(workspace: UUID, index: Int, count: Int, parentID: UUID?)` (read via
      `store.session(withID: anchorID)?.parentID`).
- [x] `createSession` (`:124`): add a `--parent` branch BEFORE the after/before branch — resolve the parent
      sid across the store (reuse `resolveAnchorLocation`), then
      `makeSessionResponse(in: store, workspaceID: parentLocation.workspace, options: options,
      parentID: parentSessionID)` with `at: nil` (last-child insert handled in `addSession`, Task 3). In the
      existing after/before branch, pass `parentID: location.parentID` so the placed session INHERITS the
      anchor's parent (sibling placement at any depth).
- [x] `makeSessionResponse` (`:557`): add `parentID: UUID? = nil`; forward it into
      `store.addSession(..., parentID: parentID)`.
- [x] `moveSession` app action: handle `.parent(anchor:)` — resolve `--target`; if anchor non-nil resolve it
      across the store and call `store.reparentSession(targetID, to: anchorID)`; if nil call
      `store.reparentSession(targetID, to: nil)`. Handle `.place(anchor:after:)` (existing) so it ALSO
      adopts the anchor's parentID: after the positional move, call `store.reparentSession(targetID, to:
      anchorParentID)` (or fold parent-adoption into the move to avoid a double reload — implementer's call,
      but the end state must be: placed session's parentID == anchor's parentID). Return `result.id`.
- [x] E2E (`ControlAPIUITests`, isolated `.debug` bundle + `AGTERM_STATE_DIR`/socket, `relaunch(withSnapshot:)`
      + `pollSessionOrder`/`pollSessionCounts`, mirror `testSessionNewPlaceRelativeToAnchor`):
      `session new --parent <sid>` creates a child (assert `tree` node `parentID`); `session move --parent`
      reparents; `session move --unparent` promotes to top-level; `session new --after <child>` inherits the
      child's parent; error guards (`--parent` + `--workspace`, `--parent` + `--after`,
      `--parent`+`--unparent`).
- [x] `make build` + `make lint` + the new e2e cases pass — green before Task 6.

### Task 6: CLI — `session new --parent`, `session move --parent`/`--unparent` (`agtermctlKit`)

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (`struct New` `:26`, `struct Move` `:136`)
- Test: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] `struct New`: add `@Option(name: .long, help: "Create the session as a CHILD of this anchor session
      (id/prefix/active); it nests under the parent in the sidebar. Mutually exclusive with
      --workspace/--workspace-name and --after/--before.") var parent: String?`. In `validate()`: reject
      `parent` with `after`/`before` and with `workspace`/`workspaceName`. In `makeRequest()`, thread
      `parent` into `ControlArgs(...)`.
- [x] `struct Move`: add `@Option(name: .long, help: "Reparent the session under this anchor session
      (id/prefix/active).") var parent: String?` and `@Flag(name: .long, help: "Promote the session to
      top-level (remove its parent).") var unparent = false`. In `validate()`: reject `parent`+`unparent`
      together, and either with `to`/`after`/`before`/positional `workspace`; require a single `--target`.
      In `makeRequest()`, build `ControlArgs(parent:)` / `ControlArgs(unparent: true)`.
- [x] Tests (`CommandsTests`): `session new --parent <sid>` maps to `ControlArgs.parent`; `session move
      --parent <sid> --target <sid>` and `--unparent --target <sid>` map correctly; `validate()` rejection
      messages for each new conflict (mirror `sessionMoveRejectsWorkspaceAndTo`).
- [x] `cd agtermCore && swift test` — green before Task 7.

### Task 7: Sidebar — nested outline, expansion, reveal, roll-up (app)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift` (data source `:709-722`; `TreeShape` `:335`, `RowContent`
  `:343`, `currentShape` `:391`; `rebuildAndReload` `:450`; expand/collapse delegates `:580-595`;
  `syncSelection` `:608`; `expandedWorkspaceIDs` `:140` → add `expandedSessionIDs`)
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift` (roll-up badge/status on collapsed parents)
- Modify: `agterm/Views/SidebarRowViews.swift` (`SidebarNode` build helper if needed)
- Test: host-free coverage rides Task 2/3; sidebar wiring is verified by the Task 12 XCUITest (no app unit host).

- [x] `rebuildAndReload` SidebarNode build: instead of one flat `session` child list per workspace, build a
      **nested** `SidebarNode` tree from each workspace's sessions using `parentID` (a session node's
      `children` are its direct children in array order). Reuse the id-keyed `nodeCache` so identity/expansion
      survive reloads.
- [x] Data source: `isItemExpandable` returns true for a workspace node OR a session node with non-empty
      `children`. `numberOfChildrenOfItem`/`child` already read `node.children`, so they work unchanged once
      the nested tree is built.
- [x] `TreeShape`: change `sessionIDs: [UUID]` to carry parent structure — `sessions: [(id: UUID, parentID:
      UUID?)]` (or a parallel `parentIDs: [UUID?]`). REQUIRED: a promote that preserves linear order but
      changes depth (e.g. `[A, A/b]` → `[A, b]`) must still count as a shape change and rebuild.
- [x] `expandedSessionIDs: Set<UUID>` beside `expandedWorkspaceIDs`; seed from `store.workspaces.flatMap
      { $0.sessions }.filter(\.isExpanded)` (parent sessions only), re-apply after `reloadData()` in
      `rebuildAndReload` (expand session nodes in `expandedSessionIDs`, under `suppressExpansionPersist`).
- [x] Expand/collapse delegates (`:580-595`): handle `node.kind == .session` too — update
      `expandedSessionIDs` and, unless suppressed, `store.setSessionExpanded(node.id, expanded:)`.
- [x] `syncSelection` (`:608`): before the `row(forItem:)` lookup, expand the FULL ancestor chain of the
      selected session (`SessionTree.ancestorIDs` over the workspace's nodes → `expandItem` each ancestor
      session node and the owner workspace) so selecting a collapsed descendant reveals it, then
      `scrollRowToVisible`. Generalizes the existing collapsed-workspace reveal.
- [x] `RowContent`: add `rolledUpUnseen: Int` and `rolledUpAttention: Bool` (a collapsed parent shows the
      aggregate of its hidden descendants; an expanded parent or a leaf uses its own values). Fold each
      session's `parentID`/`isExpanded`/descendant unseen+status into the `updateNSView` observed read so a
      hidden descendant's badge/status change reloads the collapsed parent row.
- [x] `WorkspaceSidebar+RowRendering.swift`: when a session node is collapsed and has descendants, render the
      rolled-up unseen badge + attention glyph (reuse `applyBadge`/`StatusIconView`); expanded parents render
      their own values as today. Row icon/label unchanged (native disclosure triangle indicates children).
- [x] `make build` + `make test-app` + `make lint` — green before Task 8.

### Task 8: Drag-to-reparent (app + `agtermCore`)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift` (validate/accept drop)
- Modify: `agtermCore/Sources/agtermCore/SidebarDrop.swift` (subtree-aware helper + cycle guard)
- Test: `agtermCore/Tests/agtermCoreTests/SidebarDropTests.swift`; wiring via Task 12 XCUITest

**Interfaces produced:**
```swift
extension SidebarDrop {
    /// Resolves a drop of `sourceIDs` (a dragged block) ONTO a session row (→ become its children) or
    /// between rows at a target depth, into (newParentID, destinationIndex) within one workspace, or nil
    /// for a no-op / illegal (cross-workspace, or a cycle — dropping a parent onto its own descendant).
    public static func resolveReparent(order: [SessionTree.Node], sourceIDs: [UUID],
                                       onto targetID: UUID?, workspace: UUID) -> (parentID: UUID?, destination: Int)?
}
```

- [x] `SidebarDrop.resolveReparent`: reject when `targetID` is the source or any of its descendants
      (`SessionTree.isSelfOrDescendant`); compute the new parentID (the drop target, or nil for a top-level
      gap) and the post-removal destination index using the existing block-move arithmetic; nil for a no-op
      (same parent + same slot).
- [x] `WorkspaceSidebar+DragDrop.swift`: in `validateDrop`, when AppKit's proposed `item` is a session node
      accept it as `.move` (nest) — NSOutlineView's outline drop already hands the intended parent item; in
      `acceptDrop`, map pasteboard ids → source ids, call `resolveReparent`, then
      `store.reparentSession(sourceRoot, to: resolved.parentID)` (single) or the batch equivalent. Keep the
      existing workspace-row and cross-workspace drops working (a cross-workspace drop clears parentID via
      the Task 3 `moveSession` rule).
- [x] Tests (`SidebarDropTests`): drop a leaf onto a session → parentID set, correct slot; drop a parent
      onto an outside node → whole block moves; drop a parent onto its own child → nil (cycle); drop a child
      to a top-level gap → parentID nil; same-parent same-slot → nil no-op.
- [x] `cd agtermCore && swift test` + `make build` + `make lint` — green before Task 9.

### Task 9: GUI affordances — New Child Session + cascade-close confirm (app)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+ContextMenu.swift` (`:131` row menu; `addSession` `:266`)
- Modify: `agterm/AppActions.swift` (`:117` `newSession`; add `newChildSession`)
- Modify: `agterm/agtermApp+Menus.swift` (session menu)
- Modify: the active-session close path / `AppActions` delete-confirm (reuse `confirmDelete(name:sessionCount:)`)
- Test: Task 12 XCUITest

- [x] `AppActions`: add `newChildSession(of parentSessionID: UUID)` — resolve the parent's workspace via
      `store.sessionLocation`, call `store.addSession(toWorkspace:cwd: resolvedNewSessionCwd(), parentID:
      parentSessionID)`, then select + focus (matching `newSession`).
- [x] `WorkspaceSidebar+ContextMenu.swift`: add a **New Child Session** item (and **New Child (Open
      Directory…)**) to the SESSION row menu, wired to `newChildSession`. Accessibility id `new-child-session`.
- [x] `agtermApp+Menus.swift`: add "New Child Session" to the session actions group (gated on a selected
      session), sharing the `AppActions` seam.
- [x] Cascade-close confirm: where a session close is initiated with descendants present, confirm via the
      existing `confirmDelete(name:sessionCount:)` showing the descendant count, then close
      `store.sessionSubtreeIDs(id)` as one grouped soft/hard close (Task 3). A childless session closes with
      no prompt, exactly as today.
- [x] `make build` + `make test-app` + `make lint` — green before Task 10.

### Task 10: (OPEN — see "Open decision") `session.collapse`/`.expand` control commands

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`Command` enum: `sessionCollapse =
  "session.collapse"`, `sessionExpand = "session.expand"`)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (`ControlActions` + arms)
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (effects → `store.setSessionExpanded`)
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (`Collapse`/`Expand` subcommands)
- Test: `ControlDispatcherTests`, `CommandsTests`, `ControlAPIUITests`

- [x] Add `Command.sessionCollapse`/`.sessionExpand` mirroring `workspace.collapse`/`.expand`; dispatcher
      arms resolve a single session target and route to `actions.setSessionExpanded(target, expanded:)`
      (new `ControlActions` method). App effect calls `store.setSessionExpanded`, then posts the
      object-scoped live-outline sync notification (mirror `setWorkspaceExpandedNotified`).
- [x] CLI `session collapse <id>` / `session expand <id>`; register under the `Session` subcommands list.
- [x] Tests: dispatcher target validation + routing; CLI parse; e2e collapse/expand reflected in `tree`
      node `collapsed`.
- [x] `cd agtermCore && swift test` + `make build` + `make lint` — green before Task 11.
- [x] ⚠️ If the reviewer cuts this task: drop it entirely, keep `ControlSessionNode.collapsed` as a
      GUI-only read-back (Task 5), and DO NOT bump the command count in Task 11 (stays 74).

### Task 11: Keep-in-sync docs

**Files:**
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`, `examples.md`, `troubleshooting.md`
- Modify: `.claude/rules/sidebar.md`, `.claude/rules/control-api.md`
- Modify: `README.md`; `site/docs.html`, `site/index.html`, `site/commands.html`

- [x] `reference.md`: document `session.new --parent`, `--after`/`--before` parent-inheritance,
      `session.move --parent`/`--unparent`, the cascade-close semantics, the `tree` node `parentID`/
      `collapsed` read-back, and (if Task 10 kept) `session.collapse`/`.expand`.
- [x] `SKILL.md`: update the `session.new`/`session.move` summary lines; bump "Command summary (74 commands)"
      → **76** ONLY if Task 10 is kept (else leave 74).
- [x] `examples.md`: add the headline recipe `agtermctl session new --parent "$AGTERM_SESSION_ID"` and a
      drag/`session move --parent` note.
- [x] `.claude/rules/sidebar.md`: add a "nested sessions" note (adjacency model, contiguity invariant,
      cascade close, expand/collapse of parent sessions, roll-up badge). `.claude/rules/control-api.md`:
      update the `session.new`/`session.move` catalog lines and the command count (74 → 76 iff Task 10).
- [x] `README.md` + `site/docs.html`: add `--parent`/nesting to the `agtermctl` session examples; update the
      count on `README.md:187` and `site/commands.html` (`:9,21,33,240`) iff Task 10; `site/index.html`
      feature list + `softwareVersion` if this ships in a version bump.
- [x] Verify the documented command count matches the dispatch catalog (grep the `Command` cases).

### Task 12: Verify acceptance criteria + XCUITest e2e

**Files:**
- Modify: `agtermUITests/SidebarUITests.swift` (or a new `NestedSessionsUITests.swift`)

- [x] XCUITest (isolated `.debug` state/socket, `mkdir windows` to skip the welcome): drive
      `agtermctl session new --parent <sid>` → assert a nested `session-row`; drag a row onto another →
      reparent; collapse the parent (disclosure triangle) → descendant rows hidden and the parent shows the
      rolled-up badge; cascade-close the parent → confirm dialog with count, subtree gone; Reopen Closed Item
      → subtree restored. Scope with `-only-testing:agtermUITests/NestedSessionsUITests`.
- [x] Verify all Overview requirements: create-as-child (control + GUI); arbitrary depth (grandchild);
      `--after`/`--before` inherit parent; drag-reparent + drag-out; cascade close with grouped undo;
      collapse/expand persists across relaunch; legacy snapshot decodes flat; non-nested tree byte-identical.
- [x] Verify invariants held: contiguity after every op (a host-free assertion helper in
      `AppStoreNestingTests`), no cycles, no cross-workspace subtree.
- [x] Full `cd agtermCore && swift test` green; `make build` clean; `make test-app` green; `make lint`
      (`--strict`) zero findings; the targeted XCUITest passes.
- [x] Verify no source file crossed 1000 lines from these edits; new logic lives in `SessionTree.swift` /
      `AppStore+Nesting.swift`.

### Task 13: Finalize

- [x] Final accuracy pass over `README.md` / site / skill.
- [x] Add a `.claude/rules/*.md` cross-reference if the nesting contract warrants its own owned note.
- [x] Move this plan to `docs/plans/completed/`.

## Technical details

- **Contiguity vs. reparent:** `reparentSession` sets the new `parentID` then re-derives the whole
  workspace order via `SessionTree.preorder`, which is the single place that restores the invariant. All
  other ops (create-child last-slot insert, subtree block move, cascade close block remove) preserve it
  without a full re-sort.
- **`--after`/`--before` parent-inheritance** is what makes reparent-by-move fall out for free: because the
  placed session adopts the anchor's `parentID`, `session move --after <child>` both positions AND nests,
  so the only genuinely new move verbs are `--parent`/`--unparent` (last-child / top-level).
- **Cascade close** feeds `sessionSubtreeIDs(id)` (tree order) into the existing grouped
  `softCloseSessions`/batch `closeSession`, so one grace timer and one Reopen record cover the subtree —
  identical to how `removeWorkspace` closes a workspace's sessions.
- **Read-back:** `ControlSessionNode.parentID` (nil omitted) reconstructs the tree client-side; `collapsed`
  (true only) mirrors the workspace convention. No new top-level tree field.
- **Wire (unchanged shape):** `{"cmd":"session.new","args":{"parent":"active"}}`,
  `{"cmd":"session.move","target":"<sid>","args":{"parent":"<sid>"}}`,
  `{"cmd":"session.move","target":"<sid>","args":{"unparent":true}}`. `result.id` = new/moved session id.

## Post-Completion
*Manual, no checkboxes — informational.*

- **Manual smoke (isolated Debug instance only):** `open -n --env AGTERM_STATE_DIR=<tmp> --env
  AGTERM_CONTROL_SOCKET=/tmp/agterm-nest.sock <Debug>/agterm.app` (after `mkdir -p "$tmp/windows"`); from a
  shell inside a session run `agtermctl --socket /tmp/agterm-nest.sock session new --parent active` and watch
  it nest; drag rows to reparent; collapse; cascade-close and Reopen. Do NOT touch the deployed app.
- **PR:** reference discussion #293's agent-spawned-session use case; keep the description short and
  goal-first; confirm the four keep-in-sync surfaces (protocol/CLI/e2e/skill+rules+site) before review.
  No changelog edit (release-only).
