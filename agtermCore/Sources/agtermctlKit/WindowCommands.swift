import ArgumentParser
import agtermCore

// MARK: - window

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window commands.",
        subcommands: [New.self, List.self, Select.self, Close.self, Rename.self, Delete.self, Resize.self, Move.self,
                      Zoom.self, Fullscreen.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create and open a window.")
        @Argument(help: "Window name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: BasicOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: name))
        }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List windows (id, name, open, active).")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowList) }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select (raise or open) a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowSelect, target: id) }
    }

    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window (its bundle is kept).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowClose, target: id) }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String
        @Argument(help: "New window name.") var name: String
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowRename, target: id, args: ControlArgs(name: name))
        }
    }

    struct Delete: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a window (keeps at least one).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowDelete, target: id) }
    }

    struct Resize: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Resize a window (frame size in points).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @Option(help: "New width in points.") var width: Int
        @Option(help: "New height in points.") var height: Int
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowResize, target: id, args: ControlArgs(width: width, height: height))
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Move a window (top-left x,y in points, relative to a display).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @Option(help: "Left edge x in points, from the display's left.") var x: Int
        @Option(help: "Top edge y in points, from the display's top.") var y: Int
        @Option(help: "Display index (default: the window's current display).") var display: Int?
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowMove, target: id, args: ControlArgs(x: x, y: y, display: display))
        }
    }

    struct Zoom: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Zoom a window (maximize-to-screen toggle).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowZoom, target: id) }
    }

    struct Fullscreen: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Toggle native macOS full screen for a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowFullscreen, target: id) }
    }
}
