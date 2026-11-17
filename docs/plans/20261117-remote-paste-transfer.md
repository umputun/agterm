# Paste and drop files and images into remote panes

## Overview
- Pasting or dropping into a remote pane (a Mac origin in Live sessions mode, or an agterm-server Linux host)
  copies what was offered to the origin and inserts the origin's path, so the program there can open it.
  Today a Finder copy or drop inserts a path that exists only on the viewer, and an image-only clipboard
  pastes nothing anywhere.
- One rule for Cmd-V (any keyboard layout), Edit > Paste, `session paste` and drops, local and remote alike:
  1. file URLs become shell-escaped paths (remote: the files and folders are copied to the origin first);
  2. otherwise text pastes as text, unchanged;
  3. otherwise an image-only clipboard is saved as a PNG and its path is pasted (local: a private cache folder
     on this Mac; remote: the origin's).
- Claude Code attaches a pasted absolute path ending in `.png`/`.jpe?g`/`.gif`/`.webp` (read from its 2.1.326
  binary), so Cmd-V of a screenshot works in a remote Claude Code with no Claude-specific code.
- Ctrl-V is unchanged: it stays the program's key, and Claude Code's own Ctrl-V keeps reading the clipboard of the
  host it runs on. Writing the image onto a Mac origin's clipboard is a backlog item, not part of this plan.

## Context (from discovery)
- Paste seam: `GhosttySurfaceView.paste(_:)` (`agterm/Ghostty/GhosttySurfaceView+Input.swift:708`) and
  `ControlServer.pasteSession` (`agterm/Control/ControlServer+SurfaceIO.swift:100`) both run libghostty's
  `paste_from_clipboard`, which reads through `GhosttyCallbacks.readClipboard` -> `pasteboardText`
  (`agterm/Ghostty/GhosttyCallbacks.swift:207-262`). Menu gate: `hasPasteboardText`.
- Cmd-V the menu does not take (a non-Latin layout, or a disabled Paste item) reaches `keyDown`, whose Command
  branch (`GhosttySurfaceView+Input.swift:87`) hands it to libghostty's `super+key_v=paste_from_clipboard`
  (`agterm/Resources/ghostty-defaults.conf:48`), kept on purpose per `.claude/rules/control-api.md:586`.
- Drop seam: `performDragOperation` -> `dropText` -> `pasteboardText` -> `insertPasted`
  (`GhosttySurfaceView+Input.swift:18-28`, `GhosttySurfaceView+IO.swift:68`).
- `readClipboard` also answers OSC 52 / Kitty reads; no transfer may start from there.
- Remote host of a surface: `linkClickRemoteSession` (`GhosttySurfaceView+Input.swift:670`) covers a remote pane,
  a scratch on its origin and an overlay running an origin job; `Session.remoteHost` gives the host and
  `ControlServer.catalogPool(forSession:)` a pooled ssh master for remote windows.
- Origin-side commands: `RemoteSession` (`agtermCore/Sources/agtermCore/RemoteSession.swift`) builds
  `ssh ... /bin/sh -c 'PATH=... && exec agtermctl ...'` lines (`pageServeCommand` is the model); `agtermctl` ships
  on Mac origins and agterm-server hosts alike, built from `agtermctlKit`. An origin CLI too old for a subcommand
  is recognized by `RemoteCommandResult.refusedArguments` (`agtermCore/Sources/agtermCore/RemoteTree.swift:18`).
- `RemoteCommandProcessRunner` (`agterm/Control/RemoteCommandProcessRunner.swift`) runs ssh with a deadline but
  sends no stdin; `RemoteCommandRunner` is public and has eight test conformers plus the agterm-linux fork.
- Control requests run one at a time on the accept thread unless listed in `ControlServer.waitsOnNetwork`
  (`agterm/Control/ControlServer.swift:635`).
- Failure and progress panels for remote work: `RemoteAttachHud` (`agterm/AppActions+RemoteAttach.swift:201`),
  a timed HUD that falls back to `notifyCommandFailure` when the HUD cannot open.

## Development Approach
- **testing approach**: Regular (code first, then tests), per task.
- complete each task fully before moving to the next; every task adds or updates tests and ends green.
- update this plan when scope changes during implementation.
- gates once at the end: `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`; while working,
  run only the touched tests (`swift test --filter`, `-only-testing:`).

## Testing Strategy
- host-free logic (precedence, bundle format, staging, retention, command lines) in `agtermCoreTests`; the
  receiver in `agtermctlKitTests`, in-process with an injected staging root plus one round trip through the built
  `agtermctl` with `HOME` pointed at a temporary folder.
- app seam in hosted tests (`make test-app`) with named `NSPasteboard`s and an injected staging root: local
  image-only paste inserts a staged path, a file URL inserts its path, text inserts text, and the menu gate agrees
  with the reader.
- no XCUITest: a remote origin is not available in CI; the remote path is covered by the command line, receiver and
  stub-runner tests plus the manual check in Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- **Host-free core (`agtermCore`)**: `PasteOffer` classifies what a paste or drop offers (file URLs, text, image
  bytes) into one of three actions; `PasteBundle` is the wire format of files, folders and an image; `PasteStaging`
  writes a bundle into a private staging folder under a root it is given and prunes old entries. The same
  `PasteStaging` code runs in the app (local image) and in `agtermctl paste receive` on the origin (remote), so
  both write identically.
- **Origin receiver (`agtermctlKit`)**: `agtermctl paste receive` reads one bundle from stdin, stages it under the
  default root, and prints the staged top-level paths as JSON. It opens no socket and needs no running app, so it
  works on any host where `agtermctl` is installed. Documented in `site/commands.html` as an internal command,
  like `page-serve`.
- **App seam**: one `GhosttySurfaceView` method decides the paste for the menu action, Cmd-V reaching `keyDown`,
  `session paste` and drops. Text and local file URLs keep today's path (`paste_from_clipboard`, or `insertPasted`
  for a drop); an image, or anything bound for a remote pane, is transferred first and the returned paths are
  inserted with `insertPasted`.
- **Progress and failure**: a transfer shows `RemoteAttachHud` progress over the session ("Paste") and closes it on
  success; a failure inserts nothing and goes through `RemoteAttachHud.fail` (too large, origin agterm too old,
  unreachable, a paste still copying). `session paste` returns the same reason as an error.
- **HUD ownership in `RemoteAttachHud`** (approved fix for every caller: Attach Remote, New/Duplicate Companion,
  remote-window actions, Paste): it opens a panel only when the session's overlay slot is empty or still holds the
  panel it opened itself. Otherwise it leaves the existing HUD or program in place, skips the progress panel, and
  reports a failure as the notification. Today `progress()` and `fail()` open unconditionally and
  `AppStore.openHud` replaces a live HUD, so a status HUD a script posted is destroyed.

## Technical Details
- **Precedence** (`PasteOffer.action`): file URLs with a usable path -> `.files`; else non-empty string -> `.text`;
  else PNG/TIFF image data -> `.image`; else nothing. Web URLs keep today's escaped-string behavior (they are text,
  not files). Local `.files` keeps today's output byte for byte. The menu gate and `draggingEntered` probe the
  image types only (no PNG conversion on validation).
- **Bundle format**: a version line, then per entry one JSON header line `{"root":N,"path":"<relative>",
  "kind":"file|dir","size":N}` followed by `size` raw bytes for a file. `root` is the offered item's index, so two
  offered files with the same name stay distinct. Paths are relative, `/`-separated, with no empty, `.`, or `..`
  component; a duplicate (root, path) is rejected, never overwritten. An unknown version is refused, and a header
  line longer than 64 KiB is rejected before parsing. Symlinks in a copied folder are skipped (never followed);
  other special files are skipped.
- **Building a bundle** runs off the main actor and stops as soon as the size or entry limit is exceeded, before
  reading the rest of a folder.
- **Limits**: 100 MB total per paste and 10,000 entries; the sender checks before sending and the receiver enforces
  again while reading.
- **Staging folder**: `PasteStaging` takes its root; callers pass the default, `FileManager`'s caches directory
  (`~/Library/Caches` on macOS, `$XDG_CACHE_HOME` or `~/.cache` on Linux) + `agterm/paste`, and tests pass a
  temporary folder. The root is created 0700, and an existing one is refused unless it is a real directory (not a
  symlink) owned by the user with mode exactly 0700. Each paste gets a fresh `<uuid>` folder with one numbered
  subfolder per offered item, holding the item under its own name (`clipboard-<timestamp>.png` for an image); paths
  are returned in offer order. Every file is opened with `O_CREAT|O_EXCL|O_NOFOLLOW` and every folder made with an
  exclusive `mkdir`, both refusing on `EEXIST`, so names that collide only by case on a case-insensitive volume are
  refused, not merged. A failed receive removes its
  partial `<uuid>` folder. Entries older than 24 hours are removed at the start of each staging.
- **Transport**: `RemoteSession.pasteReceiveCommand(host:connectTimeout:controlPath:)` builds `ssh -T ... exec
  agtermctl paste receive`. Stdin goes through a separate app-target protocol, `RemoteInputCommandRunner`, which
  `RemoteCommandProcessRunner` adopts, so the public `RemoteCommandRunner` and its conformers stay unchanged. The
  bundle is written to a 0600 file inside a fresh 0700 temporary folder, removed on success and failure alike. The
  pooled master is used when the session has one. Deadline scales with size (base 15 s + 1 s per MB). An origin
  reply with `refusedArguments` maps to "the origin's agterm is too old to receive pasted files".
- **One transfer per pane**: while a transfer runs in a pane, a further paste or drop into that pane is refused
  with the notice "a paste is still copying" before its payload is read or converted, so nothing reorders and
  nothing re-reads a newer clipboard. Typed input is untouched. The target surface is fixed when the paste is made.
- **Clipboard-read guard**: libghostty's own `paste_from_clipboard` (a user's ghostty.conf binding, the physical
  Paste key) and OSC 52 / Kitty reads reach `readClipboard`, never the seam. For a requesting surface whose program
  runs on an origin (remote pane, origin scratch, origin-job overlay), a usable file-URL offer is suppressed whole,
  including any plain-string representation of those same files: viewer paths are never synthesized from a file
  offer there. Ordinary text, web URLs and the private selection clipboard are unchanged; a suppressed text request
  completes with zero-length data. The guard starts no transfer. Docs name Cmd-V as the way to paste files there.
- **Cmd-V in `keyDown`**: Command plus the physical V key (by keycode, any layout) reaching `keyDown` goes to the
  seam instead of libghostty, unless agterm's keymap binds that chord to another action.
- **`session paste`**: `ControlActions.pasteSession` becomes `async`, as `typeSession` already is, so the reply
  carries the transfer's outcome; `.sessionPaste` joins `waitsOnNetwork` so a transfer never stalls the socket.
  Existing synchronous conformers (`AgtermServerKit`'s unserved stub, the test doubles) still satisfy the async
  requirement and need no change; only call sites gain `await`.
- **Security**: the input is the user's own pasteboard or drop; the new capability is writing files under the user's
  account on the origin the pane runs on. Only the user's gesture or `session paste` starts a transfer, never a
  program's clipboard request; the origin chooses no viewer paths; names come from the offered items and are
  validated as single path components; insertion is shell-escaped and bracketed as today.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks against a real Mac origin and an agterm-server host.

## Implementation Steps

### Task 1: Host-free paste offer, bundle and staging in agtermCore

**Files:**
- Create: `agtermCore/Sources/agtermCore/PasteOffer.swift`
- Create: `agtermCore/Sources/agtermCore/PasteBundle.swift`
- Create: `agtermCore/Sources/agtermCore/PasteStaging.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PasteOfferTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PasteBundleTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PasteStagingTests.swift`

- [x] `PasteOffer`: the precedence above as a pure classifier over file URLs, string and image data
- [x] `PasteBundle`: build a bundle from file and folder URLs (symlinks and special files skipped, stopping at the
      first exceeded limit) and from image bytes; a streaming reader that rejects bad paths, duplicates, an unknown
      version, an oversize header line, oversize totals and truncation
- [x] `PasteStaging`: take a root, create/verify it, prune entries older than 24 h, write a bundle into a fresh
      folder with `O_EXCL|O_NOFOLLOW`, remove the folder on failure, return the staged top-level paths in offer order
- [x] tests: precedence table; bundle round trip for a file, a nested folder, an image, and two files with the same
      name; every reader rejection above; symlink skipped; build stops at the limit; staging root refused when it is
      a symlink or not 0700; a case-only name collision refused; a failed write leaves no partial folder; pruning by
      age with an injected clock
- [x] run `swift test --filter 'Paste'` - must pass before task 2

### Task 2: Origin receiver and ssh transport

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/PasteCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` (register `paste`)
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Create: `agterm/Control/RemoteInputCommandRunner.swift`
- Modify: `agterm/Control/RemoteCommandProcessRunner.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/PasteCommandsTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`

- [ ] `agtermctl paste receive`: reads one bundle from stdin into `PasteStaging` at the default root, printing
      `{"paths":[...]}` or a JSON error, non-zero exit on failure; the staging work is a function taking the root
- [ ] `RemoteSession.pasteReceiveCommand(host:connectTimeout:controlPath:)` in the shape of `pageServeCommand`
- [ ] `RemoteInputCommandRunner` (app target) with `RemoteCommandProcessRunner` wiring a stdin file to the process;
      the caller writes the bundle 0600 inside a fresh 0700 temporary folder and removes it on every outcome
- [ ] tests: command line shape and host validation; receiver in-process with a temporary root for success, a
      malformed bundle and an oversize bundle; one round trip through the built `agtermctl` with `HOME` set to a
      temporary folder; a `refusedArguments` reply maps to the "too old" reason
- [ ] run `swift test --filter 'PasteCommands|RemoteSession'` - must pass before task 3

### Task 3: App paste and drop seam, local and remote

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView+IO.swift`
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`
- Modify: `agterm/Control/ControlServer+SurfaceIO.swift`
- Modify: `agterm/Control/ControlServer.swift` (`waitsOnNetwork`)
- Modify: `agterm/AppActions+RemoteAttach.swift` (`RemoteAttachHud` ownership)
- Create: `agterm/Control/ControlServer+PasteTransfer.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActions.swift`, `ControlDispatcher.swift` (async `pasteSession`)
- Modify: `agtermTests/GhosttyCallbacksTests.swift`, `agtermTests/GhosttySurfaceViewInputTests.swift`,
  `agtermTests/ControlServerSurfaceIOTests.swift`

- [ ] read the pasteboard (or drag pasteboard) into a `PasteOffer`, image data converted to PNG only when pasting
- [ ] one surface method used by `paste(_:)`, Cmd + physical V in `keyDown`, `session paste` and
      `performDragOperation`: text and local file URLs keep today's behavior; a local image is staged with
      `PasteStaging` and its path inserted; any remote `.files` or `.image` is bundled off the main actor, sent with
      `pasteReceiveCommand`, and the returned origin paths inserted into the surface fixed at invocation
- [ ] one transfer per pane, a further paste or drop refused with "a paste is still copying"
- [ ] menu gate and `draggingEntered` accept an image-only pasteboard by type probe, agreeing with the reader
- [ ] clipboard-read guard in `readClipboard`, resolving origin ownership from the requesting surface
- [ ] progress and failure through `RemoteAttachHud` ("Paste"); `pasteSession` async through `ControlActions`, the
      dispatcher and the app; `.sessionPaste` in `waitsOnNetwork`
- [ ] `RemoteAttachHud` opens only into an empty slot or its own panel, otherwise skips progress and notifies on
      failure, for every caller
- [ ] hosted tests: image-only paste inserts an existing staged PNG path under an injected root; file URL and text
      unchanged; gate and reader agree for image-only, URL-only and empty pasteboards; a keycode-only Cmd-V event
      reaches the seam; a remote pane with a stub runner inserts the returned origin paths in offer order and
      inserts nothing on a runner failure; a paste during a running transfer is refused; `session paste` returns
      the failure reason text; with named pasteboards on a remote surface, the guard returns zero-length data for
      file URLs and for file URLs plus their alternate string, and passes ordinary text and selection text unchanged;
      `RemoteAttachHud` with a preexisting HUD leaves it and notifies on failure, and with a HUD posted by another
      caller during the operation leaves that one too, while its own progress panel is still closed on success
- [ ] run the touched hosted test classes with `-only-testing:` - must pass before task 4

### Task 4: Docs, skill, backlog, and final gates

**Files:**
- Modify: `site/docs.html`, `site/commands.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`,
  `plugins/agterm/skills/agterm/examples.md`
- Modify: `.claude/rules/libghostty.md`, `.claude/rules/control-api.md`, `ARCHITECTURE.md`
- Create: `docs/backlog/mac-origin-clipboard-image-for-ctrl-v.md`

- [ ] docs.html: paste and drop section states the three-step rule, the remote copy, the size limit, the
      one-transfer-per-pane refusal and where files are kept; commands.html and the skill's `session paste` entry say
      the same, with Cmd-V (not Ctrl-V) as the way to paste an image into Claude Code in a remote pane, and that a
      custom ghostty.conf paste binding or the Paste key pastes no files in a remote pane; commands.html lists
      `paste receive` as an internal command
- [ ] rules: the paste seam, why `readClipboard` never transfers, the Cmd-V `keyDown` route, and the bundle/staging
      contract, each stated once; control-api.md's CLI-only exemptions count goes from three to four with
      `paste receive`; menu-actions.md's Attach Remote HUD paragraph states that a HUD already shown is kept
      and the failure goes to the notification
- [ ] backlog item: writing the image onto a Mac origin's clipboard so a program's own Ctrl-V finds it, with the
      shared-clipboard cost
- [ ] verify every Overview requirement; run `make build`, `cd agtermCore && swift test`, `make test-app`,
      `make lint` once
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Manual checks*

- Mac origin (Live sessions, attached from this Mac): Cmd-V of a screenshot into Claude Code attaches it; a Finder
  copy of a file and of a folder pastes origin paths that exist there; a drop does the same; an over-limit folder
  shows the reason and inserts nothing; Cmd-V on a non-Latin layout behaves the same.
- agterm-server Linux host: the same cases in a remote window pane.
- Local pane: Cmd-V of a screenshot into Claude Code attaches it; text and Finder-file paste unchanged.
