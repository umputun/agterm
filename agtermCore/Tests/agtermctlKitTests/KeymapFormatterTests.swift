import Testing
import agtermCore
@testable import agtermctlKit

struct KeymapFormatterTests {
    @Test func formatsCustomCommandErrorOptions() {
        let payload = ControlKeymap(path: "/tmp/keymap.conf", actions: [], commands: [
            ControlKeymapCommand(name: "quiet"),
            ControlKeymapCommand(name: "default", errorHud: true),
            ControlKeymapCommand(name: "placed", shortcut: "ctrl+a>p", errorHud: true,
                                 errorPosition: .topRight, errorPane: .left)
        ], diagnostics: [])
        let output = SocketClient.formatKeymap(payload)
        #expect(output.contains("    quiet  (palette only)\n"))
        #expect(output.contains("    default  (palette only)  --error-hud --error-position center\n"))
        #expect(output.contains("    placed  ctrl+a>p  --error-hud --error-position top-right --error-pane left"))
    }

    @Test func formatsKeymapWithEveryActionAndTheLiveMenu() {
        let keymap = Keymap(builtinOverrides: [.closeSession: Chord(mods: [.command], key: "e")], commands: [])
        let payload = ControlKeymap.project(
            keymap: keymap, diagnostics: [KeymapDiagnostic(line: 3, message: "unknown action")],
            path: "/tmp/keymap.conf",
            menu: [ControlKeymapMenuItem(menu: "File", title: "Close", chord: "cmd+w", selector: "performClose:")]
        )

        let out = SocketClient.formatKeymap(payload)

        #expect(out.contains("keymap: /tmp/keymap.conf"))
        #expect(out.contains("* close_session"), "an overridden action is marked")
        #expect(out.contains("cmd+e"))
        #expect(out.contains("line 3: unknown action"))
        #expect(out.contains("cmd+w  File ▸ Close"), "the live menu chord is listed for comparison")
        // every action appears, keyless ones included, so the listing is the whole set
        for action in BuiltinAction.allCases { #expect(out.contains(action.rawValue)) }
    }

    // line 0 is the whole-file sentinel, not a real line (SettingsView.diagnosticLine drops it too).
    @Test func formatsKeymapDroppingTheLineNumberForWholeFileDiagnostics() {
        let payload = ControlKeymap.project(
            keymap: Keymap(builtinOverrides: [:], commands: []),
            diagnostics: [KeymapDiagnostic(line: 0, message: "conflicts with a built-in; keybind dropped"),
                          KeymapDiagnostic(line: 7, message: "unknown action")],
            path: "/tmp/keymap.conf"
        )

        let out = SocketClient.formatKeymap(payload)

        #expect(out.contains("    conflicts with a built-in; keybind dropped"))
        #expect(!out.contains("line 0"), "the sentinel must not be printed as a line number")
        #expect(out.contains("line 7: unknown action"), "a real line number is still shown")
    }

    // a disabled item's chord is inert, so the marker is the one fact that explains a dead binding.
    @Test func formatsKeymapMarkingDisabledMenuItems() {
        let payload = ControlKeymap.project(
            keymap: Keymap(builtinOverrides: [:], commands: []), diagnostics: [], path: "/tmp/keymap.conf",
            menu: [ControlKeymapMenuItem(menu: "Navigate", title: "Focus Left Pane", chord: "cmd+opt+left",
                                         selector: "menuAction:", enabled: false),
                   ControlKeymapMenuItem(menu: "File", title: "New Session", chord: "cmd+n",
                                         selector: "menuAction:")]
        )

        let out = SocketClient.formatKeymap(payload)

        #expect(out.contains("cmd+opt+left  Navigate ▸ Focus Left Pane  (disabled)"))
        #expect(out.contains("cmd+n  File ▸ New Session\n") || out.hasSuffix("cmd+n  File ▸ New Session"),
                "an enabled row carries no marker")
    }

    @Test func formatsKeymapJoiningAlternativesWithTheFilesOwnSeparator() {
        let parsed = parseKeymap("map cmd+t|ctrl+space>s toggle_split\nmap ctrl+a>g toggle_sidebar")
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        let out = SocketClient.formatKeymap(payload)
        func binds(_ action: String) -> String? {
            out.split(separator: "\n").first { $0.contains(" \(action) ") }?
                .split(separator: " ").last.map(String.init)
        }

        #expect(binds("toggle_split") == "cmd+t|ctrl+space>s")
        #expect(binds("toggle_sidebar") == "ctrl+a>g", "an unbound action lists its alternatives alone")
        #expect(binds("first_session") == "-", "an action with no binding at all still prints a dash")
    }

    // the compatibility invariant: the same `|`-free fixture agtermCoreTests pins, rendered exactly as the
    // pre-alternatives formatter rendered it — every expected byte below came from that formatter.
    @Test func formatsAPipeFreeKeymapByteIdenticallyToThePreAlternativesOutput() {
        let fixture = """
        # regression fixture: no `|` anywhere, no multi-chord map
        map cmd+shift+e toggle_split
        map t toggle_sidebar
        map ctrl+cmd+left focus_left_pane
        map cmd+w new_session

        command "Deploy" cmd+shift+y ./deploy.sh
        command "Open Notes" vim {AGT_SESSION_PWD}/notes.md
        command "Clash" command+shift+e echo clash
        command "First" control+shift+g echo one
        command "Second" ctrl+shift+g echo two
        """
        let parsed = parseKeymap(fixture)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        #expect(SocketClient.formatKeymap(payload) == """
        keymap: /tmp/keymap.conf

        actions:
            new_window                  cmd+opt+n
            rename_window               -
            delete_window               -
            previous_window             -
            next_window                 -
            new_workspace               cmd+shift+n
            rename_workspace            -
            delete_workspace            -
            new_session                 cmd+n
            open_directory              cmd+o
            rename_session              -
            duplicate_session           -
            new_companion               -
            duplicate_companion         -
            convert_companion           -
            close_session               cmd+w
            reopen_recent               cmd+shift+t
            undo_close                  cmd+z
            clear_status                -
            increase_font_size          cmd++
            decrease_font_size          cmd+-
            reset_font_size             cmd+0
          * toggle_split                cmd+shift+e
            toggle_horizontal_split     cmd+shift+d
            toggle_scratch              cmd+j
            toggle_terminal_zoom        cmd+shift+return
            toggle_overlay              cmd+shift+j
            toggle_search               cmd+f
          * toggle_sidebar              t
            select_theme                -
            toggle_fullscreen           ctrl+cmd+f
            toggle_flagged_view         -
            toggle_flag                 cmd+shift+f
            focus_workspace             -
            toggle_workspace_filter     -
            previous_workspace          -
            next_workspace              -
            toggle_workspace_collapse   -
          * focus_left_pane             ctrl+cmd+left
            focus_right_pane            cmd+opt+right
            previous_session            cmd+opt+up
            next_session                cmd+opt+down
            previous_attention_session  ctrl+opt+up
            next_attention_session      ctrl+opt+down
            first_session               -
            last_session                -
            quick_terminal              ctrl+`
            session_palette             ctrl+p
            command_palette             ctrl+shift+p
            custom_command_palette      ctrl+shift+o
            show_attention              ctrl+shift+i
            dashboard                   cmd+shift+g
            attach_remote               cmd+shift+r
            open_remote_window          -
            detached_sessions           -
            new_remote_session          -
            edit_flagged_sessions       -
            edit_focused_workspaces     -

        commands:
            Deploy  cmd+shift+y
            Open Notes  (palette only)
            Clash  (palette only)
            First  (palette only)
            Second  (palette only)

        diagnostics:
            line 5: chord conflicts with built-in 'close_session'; map skipped
            custom command 'Clash' shortcut 'command+shift+e' conflicts with a built-in; keybind dropped
            custom command 'First' shortcut 'control+shift+g' conflicts with custom command 'Second'; keybind dropped
            custom command 'Second' shortcut 'ctrl+shift+g' conflicts with custom command 'First'; keybind dropped
        """)
    }

    @Test func formatsKeymapWithoutOptionalSectionsWhenEmpty() {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")

        let out = SocketClient.formatKeymap(payload)

        #expect(!out.contains("commands:"))
        #expect(!out.contains("diagnostics:"))
        #expect(!out.contains("menu:"), "menu is omitted, not printed empty, when the caller supplied none")
        #expect(out.contains("close_session"))
    }

    @Test func formatsOpenRulesInTheirOwnSection() {
        let payload = ControlKeymap(path: "/tmp/keymap.conf", actions: [], commands: [], diagnostics: [],
                                    openers: [ControlKeymapOpener(selectors: ["*.md", "README"], command: "mdview", line: 3)])
        #expect(SocketClient.formatKeymap(payload) == "keymap: /tmp/keymap.conf\n\nactions:\n\nopeners:\n    *.md,README  mdview")
    }

    @Test func formatsAnOpenRulesFailurePanelOptions() {
        let payload = ControlKeymap(path: "/tmp/keymap.conf", actions: [], commands: [], diagnostics: [],
                                    openers: [ControlKeymapOpener(selectors: ["*.md"], command: "mdview", line: 1, errorHud: true,
                                                                  errorPosition: .topRight, errorPane: .left)])
        #expect(SocketClient.formatKeymap(payload).hasSuffix("\n    *.md  --error-hud --error-position top-right --error-pane left  mdview"))
    }
}
