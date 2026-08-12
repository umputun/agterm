# agterm - a simply good terminal with a full control API

[![Build Status](https://github.com/umputun/agterm/workflows/build/badge.svg)](https://github.com/umputun/agterm/actions) [![Coverage Status](https://coveralls.io/repos/github/umputun/agterm/badge.svg?branch=master)](https://coveralls.io/github/umputun/agterm?branch=master)

**[agterm.com](https://agterm.com)** · [Documentation](https://agterm.com/docs) · [Command reference](https://agterm.com/commands) · [Cookbook](cookbook/)

`agterm` is a native macOS terminal with a deliberately small interface and a full control API. Shells are organized into named workspaces, each holding the sessions for one project or context, and that hierarchy is the whole model: there is nothing else to learn before it is useful. Everything it holds is also an object a script can address. The bundled `agtermctl` creates sessions and types into them, reads a pane's text back, runs a program in an overlay and returns its exit status, sets a session's status glyph, opens the native picker, moves windows, and reads all of that state back out over a local socket.

The motivation is specific: running several coding agents at once means many long-lived sessions, each progressing on its own, and a tabbed terminal loses track of them quickly. Each agent works in a named session and reports whether it is active, blocked, or done, so it is obvious which one needs you. An installable skill teaches an agent the control model, so it can drive the terminal itself. None of that is a special agent mode; it is the same control surface anything else uses. With nothing scripted at all it is a capable general-purpose terminal for everyday multi-project work.

The design is deliberately minimal: it covers the use cases above and stops there. Features come in two kinds. One is just enough to get the work done. The other is the small set of things other terminals get wrong, done the way they should have been. There is no deep agent integration and no attempt to invent a new way of working with agents. You get a sensible minimum out of the box, plus a complete control API and CLI on top, so anything past the defaults you build yourself instead of waiting for it to ship.

What it does:

- **Workspaces.** Sessions are grouped under named workspaces like "work" and "personal", which keeps a screen of concurrent sessions organized. You reach a session by name, by recency, or from the keyboard.
- **Control API and CLI.** A bundled tool, `agtermctl`, drives almost everything over a local socket: create sessions, type into them, run a program in an overlay and read its exit status, move and resize windows, or post a notification tied to a specific session. A script or an agent can set up and drive its own layout, and send you a notification from the session it was working in.
- **Splits, scratch, and overlays.** Split a session into two shells, open a scratch terminal over it, or run a program in a full or floating overlay without disturbing the shell underneath.
- **Agent skill.** An installable skill (Help ▸ Install Agent Skill…) teaches Claude Code or Codex the control model and the `agtermctl` commands, so an agent running inside agterm can build its own layout, run overlays, manage windows, and show images inline without you explaining the API.
- **Agent status.** A coding agent reports its state (active, blocked, or completed) onto its session's row, so you can see which of many running agents needs you. Status hooks for Claude Code, Codex, Pi, OpenCode, and other agents install from Help ▸ Install Agent Status Hooks….

For the real terminal work, rendering, VT parsing, and shell I/O, `agterm` embeds [Ghostty](https://ghostty.org)'s engine (libghostty); everything above is `agterm`'s own.

![agterm](docs/screenshots/main.png)

<details>
<summary>More screenshots</summary>

The dashboard: several sessions' live output in one view-only grid, watched at once. A single click drops into any of them:

![Dashboard](docs/screenshots/dashboard.png)

An agent's interactive prompt mid-session, with attention glyphs on the sessions that need you:

![Agent prompt](docs/screenshots/agent-prompt.png)

The attention list, collecting every session that needs you, sorted blocked then active then completed:

![Attention list](docs/screenshots/attention.png)

A split session (agent and shell side by side) with the action palette open:

![Action palette](docs/screenshots/action-palette.png)

A full-screen diff TUI running inside a session:

![Diff TUI](docs/screenshots/diff-tui.png)

A file manager in a floating overlay over the active session:

![Floating overlay](docs/screenshots/floating-overlay.png)

The fuzzy session palette for jumping to any session by name:

![Session palette](docs/screenshots/session-palette.png)

A session's right-click context menu:

![Context menu](docs/screenshots/context-menu.png)

The keymap editor:

![Keymap editor](docs/screenshots/keymap-editor.png)

A split session, two panes side by side on different color themes:

![Split session](docs/screenshots/split-theme.png)

A file open in the quick terminal, the window's shared scratch overlay:

![Quick terminal](docs/screenshots/quick-terminal.png)

</details>

## The model

- **Window.** A top-level bundle of workspaces and sessions in its own macOS window, with its own sidebar tree.
- **Workspace.** A named group of sessions for one project or context.
- **Session.** One running shell with a name, a working directory, and its own scrollback. It is the row you see in the sidebar, and it keeps running while you work in another one.
- **Split and scratch.** A session can split into two shells side by side, both sharing the one sidebar row, and it can open a scratch terminal over itself for a quick aside.
- **Overlay.** One program running in a temporary terminal over a session. It disappears when the program exits and leaves the shell underneath unchanged.

## Install

Pre-built releases are for **Apple Silicon (arm64) Macs running macOS 14 or later**.

Releases are signed with a Developer ID certificate and notarized by Apple, so macOS Gatekeeper opens them with no extra steps.

Homebrew:

```sh
brew install --cask umputun/apps/agterm
```

The cask also installs the `agtermctl` command-line tool, so cask users should not run the in-app installer as well.

Direct download:

Download the latest `.dmg` from the [releases page](https://github.com/umputun/agterm/releases), open it, and drag `agterm.app` into `/Applications`.

### Optional Help-menu installers

The app's **Help** menu has three one-time installers. None are needed to use agterm as a terminal; each connects it to a wider workflow, and you can run any of them later. The first launch on a machine points them out in a welcome dialog, which offers the skill and the status hooks and never appears again.

- **Install Command Line Tool…** puts the bundled `agtermctl` on your `PATH` (a symlink in `/usr/local/bin`) so you can script the app from a shell. The Homebrew cask already installs it, so cask users can skip this one. See [Scripting agterm](#scripting-agterm).
- **Install Agent Status Hooks…** lets a coding agent (Claude Code, Codex, Pi, OpenCode, or others) report its state onto its session's sidebar row, so you can tell at a glance which of several running agents is active, blocked, or finished. See [Agent status](#agent-status).
- **Install Agent Skill…** teaches Claude Code or Codex how to drive agterm through `agtermctl`, so an agent running inside a session can build its own layout, run overlays, and manage windows without you explaining the API. It drives the app through the command-line tool, so install that one too.

## Scripting agterm

## Related projects

A small ecosystem has grown around agterm. These are independent projects, not maintained here.

**Built on agterm**

- [agterm-linux](https://github.com/melonamin/agterm-linux) by [@melonamin](https://github.com/melonamin) is a Linux port (GTK4/libadwaita) built on the shared, host-free `agtermCore`. The macOS app stays here; the Linux frontend lives in that fork.
- [Rook](https://github.com/jokius/rook) by [@jokius](https://github.com/jokius) is a native macOS terminal fork that takes agterm in a different direction, with features outside agterm's intended scope. Both projects are deliberately opinionated, with different ideas about where a focused agent terminal should stop.

**Reimplementation**

- [agwinterm](https://github.com/yeroo/agwinterm) by [@yeroo](https://github.com/yeroo) is a native Windows terminal for AI coding agents (C#, Win32/Direct2D), an independent from-scratch homage to agterm's design.

**Companion tools**

- [agterm-remote](https://github.com/k0nsta/agterm-remote) carries agterm's agent-status colors and pushes to agents running in a remote tmux over SSH.
- [pi-agterm](https://github.com/khanton/pi-agterm) is a pi extension that reports agent status onto agterm's status indicator.
- [agterm-experimental](https://github.com/rashpile/agterm-experimental) collects custom skills and scripts for agterm.

## Attribution

agterm embeds **libghostty**, the terminal engine from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT). It does all the real terminal work: rendering, VT parsing, and shell I/O. agterm builds it from upstream source at a pinned commit via `scripts/setup.sh`, with no fork and no prebuilt binary.

The way agterm drives libghostty's C API from a SwiftUI/AppKit app, under the Swift 6 strict-concurrency toolchain, was learned from [macterm](https://github.com/thdxg/macterm) (`thdxg/macterm`, MIT). The libghostty bridge files (`GhosttyApp`, `GhosttyCallbacks`, `GhosttyResources`, `GhosttySurfaceView`, `WindowAppearance`) are adapted from it and each carries an attribution comment. The model, sidebar, persistence, control channel, and multi-window code are original to agterm.

SwiftUI guidance during development came from the [SwiftUI Agent Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) by Antoine van der Lee (MIT). Special thanks to [@ksenks](https://github.com/ksenks) for recommending it.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more information.
