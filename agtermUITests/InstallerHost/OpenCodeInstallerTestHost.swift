import AppKit
import agtermCore

@main
struct OpenCodeInstallerTestHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = InstallerHostDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class InstallerHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var isInstalling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application)
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = NSMenu(title: "Help")
        let install = NSMenuItem(title: "Install Agent Status Hooks…", action: #selector(installOpenCode), keyEquivalent: "")
        install.target = self
        help.submenu?.addItem(install)
        menu.addItem(help)
        NSApp.mainMenu = menu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OpenCode installer UI test"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func installOpenCode() {
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                let environment = ProcessInfo.processInfo.environment
                guard let state = environment["AGTERM_STATE_DIR"], !state.isEmpty,
                      let resources = Bundle.main.resourceURL else {
                    throw NSError(domain: "InstallerTestHost", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing installer test fixture"])
                }
                let root = URL(fileURLWithPath: state, isDirectory: true)
                let home = root.appendingPathComponent("opencode-home")
                let bin = root.appendingPathComponent("opencode-bin")
                let command = bin.appendingPathComponent("opencode")
                // Sandboxed UI-runner executables get EPERM when the app launches them; create the fixed fixture here.
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try "#!/bin/sh\nprintf '%s\\n' \"$AGTERM_UITEST_OPENCODE_VERSION\"\n".write(to: command, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
                let outcome = try await AgentHooksInstaller.installOpenCodePlugin(
                    home: home, scriptDirectory: resources.appendingPathComponent("agent-status"),
                    environment: ["HOME": home.path, "PATH": bin.path,
                                  "AGTERM_UITEST_OPENCODE_VERSION": environment["AGTERM_UITEST_OPENCODE_VERSION"] ?? "unknown-version"]
                )
                let alert = AgentHooksInstaller.makeAlert(
                    style: outcome.result.isWarning ? .warning : .informational,
                    title: "OpenCode Status Plugin", text: AgentHooksInstaller.opencodeText(outcome.result, version: outcome.version), docs: nil
                )
                alert.runModal()
            } catch {
                let alert = AgentHooksInstaller.makeAlert(style: .warning, title: "Install Failed", text: error.localizedDescription, docs: nil)
                alert.runModal()
            }
        }
    }
}
