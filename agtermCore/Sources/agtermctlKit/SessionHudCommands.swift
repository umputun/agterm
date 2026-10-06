import ArgumentParser
import Foundation
import agtermCore

// The `session hud` subcommands, split out of `SessionCommands.swift` for the file size limit.
extension Session {
    /// The passive message panel. `Open` is the default subcommand, so posting one is
    /// `agtermctl session hud "gathering options…"`; a message that is literally `update` or `close` needs
    /// the explicit `hud open` verb. Message length and control characters are the dispatcher's to reject —
    /// only what needs no socket is checked here.
    struct Hud: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Post, update, or close a passive message panel over a session.",
            subcommands: [Open.self, Update.self, Close.self],
            defaultSubcommand: Open.self
        )

        static let stickyHelp = """
            Put the panel flush against the edge or corner --position names, with no margin; center has no \
            edge and ignores it. Add --size-percent 100 for a strip across the pane.
            """
        static let noFrameHelp = "Draw no border, no rounded corners and no blank row above and below the text."

        /// `--position` help and validation both derive from `HudPosition`, so a new case reaches each.
        /// Accepts the `top`/`bottom` aliases exactly as the dispatcher does, for the reason
        /// `validateSpinnerStyle` states about `none`: refusing one here would fail a value the identical
        /// raw-socket request takes.
        static func validatePosition(_ position: String?) throws {
            if let position, HudPosition.parse(position) == nil {
                throw ValidationError("position must be one of: \(HudPosition.acceptedNamesPhrase)")
            }
        }

        /// Shared by open and update, which both set the panel's text color; `--background-color` has no
        /// update counterpart because only the text color rides the header a live panel re-reads.
        static func validateTextColor(_ textColor: String?) throws {
            if let textColor, !WatermarkConfig.isValidColorHex(textColor) {
                throw ValidationError("text-color must be a #rrggbb hex value")
            }
        }

        /// Accepts `HudSpinner.noneName` beside the styles, exactly as the dispatcher does: `none` is what
        /// the read-back reports for a static panel, and refusing it here would make a value `tree` just
        /// handed the caller fail locally while the identical raw-socket request succeeds.
        static func validateSpinnerStyle(_ style: String?) throws {
            if let style, style != HudSpinner.noneName, HudSpinner(rawValue: style) == nil {
                throw ValidationError("spinner style must be one of: \(HudSpinner.acceptedNamesPhrase)")
            }
        }

        /// Rejects what cannot be scheduled rather than clamping it, matching the dispatcher so the same value
        /// fails the same way over a raw socket.
        static func validateHideAfter(_ seconds: Double?) throws {
            if let seconds, !HudSpec.isValidHideAfter(seconds) {
                throw ValidationError("hide-after must be 0...\(Int(HudSpec.maxHideAfter)) seconds")
            }
        }

        /// The one spinner value the socket carries, from the two ways to ask for one: `--spinner-style`
        /// names it and turns it on by itself, so the bare `--spinner` flag is only needed for the default.
        /// Nil when neither is given, which is the static panel.
        ///
        /// An explicit `--spinner-style none` also resolves to nil, and beats a bare `--spinner` beside it:
        /// naming a value is the more specific instruction, which is the same rule that makes a named style
        /// win over the flag's default.
        static func spinnerValue(spinner: Bool, style: String?) -> String? {
            if style == HudSpinner.noneName { return nil }
            return style ?? (spinner ? HudSpinner.defaultStyle.rawValue : nil)
        }

        static func validateMessageSource(_ message: String?, file: String?) throws {
            if message == nil, file == nil { throw ValidationError("provide MESSAGE or --file") }
            if message != nil, file != nil { throw ValidationError("MESSAGE and --file are mutually exclusive") }
        }

        /// messageText is the argument, or the UTF-8 contents of `file` with CRLF line endings normalized and
        /// one trailing newline dropped: files end with one, and a plain panel rejects newlines. The dispatcher still applies every cap and rejection.
        static func messageText(_ message: String?, file: String?) throws -> String {
            guard let file else { return message ?? "" }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            } catch {
                throw ValidationError("cannot read --file \(file): \(error.localizedDescription)")
            }
            guard var text = String(data: data, encoding: .utf8) else {
                throw ValidationError("--file \(file) is not valid UTF-8")
            }
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }

        static func validateFontSize(_ points: Double?) throws {
            if let points, !HudSpec.isValidFontSize(points) {
                throw ValidationError(
                    "font-size must be \(Int(HudSpec.fontSizeRange.lowerBound))...\(Int(HudSpec.fontSizeRange.upperBound)) points")
            }
        }

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Post a message panel over the session; the session keeps focus and stays typable.")
            @Argument(help: "Message shown in the panel (omit with --file).") var message: String?
            @Option(name: .long, help: "Read the message from FILE instead of the argument.") var file: String?
            @Flag(name: .long, help: """
                Render the message as markdown, up to \(HudSpec.maxMarkdownLength) characters. A single newline inside a paragraph is a \
                soft break; end a line with two spaces or a backslash to break it. A link is underlined and opens on a command-click.
                """)
            var markdown = false
            @Option(name: .customLong("font-size"), help: """
                The panel's own font size in points, \(Int(HudSpec.fontSizeRange.lowerBound))-\
                \(Int(HudSpec.fontSizeRange.upperBound)); omit to use the session's. Fixed for the panel's life.
                """)
            var fontSize: Double?
            @Option(name: .long, help: "Dim second line under the message (e.g. what the caller is waiting on).") var detail: String?
            @Flag(name: .long, help: "Animate a spinner glyph in the panel, in the default style.")
            var spinner = false
            @Option(name: .long, help: """
                Spinner style: \(HudSpinner.acceptedNamesPhrase) \
                (default: \(HudSpinner.defaultStyle.rawValue)). Implies --spinner; \
                \(HudSpinner.noneName) leaves the panel static.
                """)
            var spinnerStyle: String?
            // the canonical nine are what `session background` shares; the aliases are this command's own,
            // so naming them in the same breath would send a caller to a --position background rejects
            @Option(name: .long, help: """
                Placement in the pane: \(HudPosition.validNamesPhrase) (default: center), the same \
                anchors session background takes. Every anchor off center holds a fixed margin at that \
                edge. Here top and bottom are also accepted, for top-center and bottom-center.
                """)
            var position: String?
            @Option(name: .long, help: "Solid background color (#rrggbb) for the panel, independent of the session's own.") var backgroundColor: String?
            @Option(name: .long, help: "Color (#rrggbb) for the panel's text; omit to keep the terminal foreground.") var textColor: String?
            @Option(name: .long, help: """
                Set the panel's WIDTH to PERCENT (1-100) of the pane instead of measuring the message; \
                bounded to \(HudLayout.minSizePercent)-\(HudLayout.maxSizePercent), or up to 100 with \
                --sticky off center. Height always follows the message.
                """)
            var sizePercent: Int?
            @Flag(name: .long, help: ArgumentHelp(Hud.stickyHelp)) var sticky = false
            @Flag(name: .customLong("no-frame"), help: ArgumentHelp(Hud.noFrameHelp)) var noFrame = false
            @Option(name: .long, help: "Anchor inside primary/left/top or split/right/bottom; omit for the whole session.")
            var pane: String?
            @Option(name: .customLong("pane-id"), help: "Stable pane token ($AGTERM_PANE_ID); overrides --pane when it resolves.")
            var paneID: String?
            @Option(name: .customLong("hide-after"), help: """
                Take the panel down by itself after SECONDS, 0...\(Int(HudSpec.maxHideAfter)); omit or 0 to \
                leave it up until something closes it. The clock runs whether or not the session is on screen.
                """)
            var hideAfter: Double?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws {
                if let backgroundColor, !WatermarkConfig.isValidColorHex(backgroundColor) {
                    throw ValidationError("background-color must be a #rrggbb hex value")
                }
                try Hud.validateTextColor(textColor)
                try Hud.validatePosition(position)
                try Hud.validateSpinnerStyle(spinnerStyle)
                try Hud.validateHideAfter(hideAfter)
                try Hud.validateMessageSource(message, file: file)
                try Hud.validateFontSize(fontSize)
                try Session.validateSizePercent(sizePercent)
                try Overlay.validatePane(pane)
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionHudOpen, target: target.target,
                               args: options.withWindow(ControlArgs(
                                   sizePercent: sizePercent, message: try Hud.messageText(message, file: file),
                                   detail: detail, spinner: Hud.spinnerValue(spinner: spinner, style: spinnerStyle),
                                   hideAfter: hideAfter, markdown: markdown ? true : nil,
                                   sticky: sticky ? true : nil, frame: noFrame ? false : nil,
                                   pane: pane, paneID: paneID, color: backgroundColor,
                                   textColor: textColor, position: position, fontSize: fontSize)))
            }
        }

        /// Repaints the live panel in place. An update replaces the whole message, so every argument it
        /// accepts must be repeated to survive, including `--spinner`, `--text-color`, and pane scope.
        /// `--background-color` is deliberately absent: the surface reads it once at creation, so only a
        /// fresh `hud` can change it, while the text color rides the header the helper re-reads every tick.
        struct Update: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Replace the panel's text in place (no re-spawn, no blink).")
            @Argument(help: "New message; it replaces the old one entirely (omit with --file).") var message: String?
            @Option(name: .long, help: "Read the new message from FILE instead of the argument.") var file: String?
            @Flag(name: .long, help: "Render the message as markdown; omit to return the panel to plain text.")
            var markdown = false
            @Option(name: .long, help: "Dim second line under the message; omit to drop the old one.") var detail: String?
            @Flag(name: .long, help: "Keep (or start) the spinner in the default style; omit to stop it.")
            var spinner = false
            @Option(name: .long, help: """
                Switch the spinner to \(HudSpinner.acceptedNamesPhrase); implies --spinner, and repaints \
                the live panel without a re-spawn. \(HudSpinner.noneName) stops it.
                """)
            var spinnerStyle: String?
            @Option(name: .long, help: "Move the panel to \(HudPosition.acceptedNamesPhrase) (default: center).") var position: String?
            @Option(name: .long, help: "Recolor the panel's text (#rrggbb); omit to return it to the terminal foreground.") var textColor: String?
            @Option(name: .long, help: """
                Resize the panel's WIDTH to PERCENT (1-100) of the pane instead of measuring the message; \
                bounded to \(HudLayout.minSizePercent)-\(HudLayout.maxSizePercent), or up to 100 with \
                --sticky off center. Height always follows the message.
                """)
            var sizePercent: Int?
            @Flag(name: .long, help: ArgumentHelp("\(Hud.stickyHelp) Omit to return the panel to its edge margin."))
            var sticky = false
            @Flag(name: .customLong("no-frame"), help: ArgumentHelp("\(Hud.noFrameHelp) Omit to bring the frame back."))
            var noFrame = false
            @Option(name: .long, help: "Anchor inside primary/left/top or split/right/bottom; omit to return to whole-session placement.")
            var pane: String?
            @Option(name: .customLong("pane-id"), help: "Stable pane token ($AGTERM_PANE_ID); repeat it on update to keep pane scope.")
            var paneID: String?
            @Option(name: .customLong("hide-after"), help: """
                Restart the panel's auto-hide at SECONDS, 0...\(Int(HudSpec.maxHideAfter)); omit or 0 to \
                cancel it, like every other option an update replaces rather than patches.
                """)
            var hideAfter: Double?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws {
                try Hud.validateTextColor(textColor)
                try Hud.validatePosition(position)
                try Hud.validateSpinnerStyle(spinnerStyle)
                try Hud.validateHideAfter(hideAfter)
                try Hud.validateMessageSource(message, file: file)
                try Session.validateSizePercent(sizePercent)
                try Overlay.validatePane(pane)
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionHudUpdate, target: target.target,
                               args: options.withWindow(ControlArgs(
                                   sizePercent: sizePercent, message: try Hud.messageText(message, file: file),
                                   detail: detail, spinner: Hud.spinnerValue(spinner: spinner, style: spinnerStyle),
                                   hideAfter: hideAfter, markdown: markdown ? true : nil,
                                   sticky: sticky ? true : nil, frame: noFrame ? false : nil,
                                   pane: pane, paneID: paneID, textColor: textColor, position: position)))
            }
        }

        struct Close: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Take the message panel down (a program overlay in the same slot is left alone).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionHudClose, target: target.target, args: options.withWindow())
            }
        }
    }
}
