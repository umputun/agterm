import Foundation

/// The one-time pointer at the optional extras under the Help menu, shown on a first launch only. Owns the
/// due-decision and the copy; the AppKit alert and the installers it runs live app-side.
public enum FirstRunWelcome {
    /// Files a previous launch leaves behind. The control socket is excluded: it is bound before the scene
    /// task runs, so its presence says nothing about earlier launches.
    static let priorStateNames = ["settings.json", "workspaces.json", "windows"]

    public static let title = "Welcome to agterm"

    public static let message = """
    agterm ships optional extras. These two install from here, and all of them from the Help menu at any time:

    The agent skill teaches Claude Code and Codex to drive agterm over its control socket.

    The agent status hooks make an agent session report active, blocked or completed in the sidebar.

    The command line tool puts agtermctl on your PATH. A Homebrew install already has it, so that one is \
    only for a direct download.
    """

    public static let skillOption = "Install the agent skill"

    public static let hooksOption = "Install the agent status hooks"

    /// Whether any prior-launch state exists in `directory`. Must be read before the app writes anything,
    /// since the first launch seeds a session and saves its window within a second of the scene appearing.
    public static func hasPriorState(in directory: URL) -> Bool {
        priorStateNames.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Whether to show the welcome: never twice, and never to a user who has run agterm before. The two
    /// terms answer different questions, so both are needed. `welcomeShown` covers a state directory that
    /// carries the flag, and `hasPriorState` covers everyone who upgraded into this feature, whose settings
    /// predate the flag and would otherwise read as a fresh install.
    public static func isDue(welcomeShown: Bool?, hasPriorState: Bool) -> Bool {
        welcomeShown != true && !hasPriorState
    }
}
