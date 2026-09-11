import Foundation
import os

/// Reopens agterm after a Live sessions reset quit. A detached shell waits for this pid to exit, then runs
/// the standard app launch; `NSWorkspace` cannot do that from the exiting process, and opening before exit
/// reaches the running instance. Arguments travel positionally, never inside the script text.
struct LiveResetRelauncher {
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "LiveResetRelauncher")

    static let script = """
    i=0
    while kill -0 "$1" 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -ge "$5" ] && exit 1
      sleep 0.2
    done
    if [ -n "$3" ]; then exec "$4" -n "$2" --env "AGTERM_STATE_DIR=$3"; fi
    exec "$4" -n "$2"
    """

    var shell = "/bin/sh"
    var open = "/usr/bin/open"
    /// Polls of 0.2 s before the waiter gives up without launching.
    var maxWaits = 300

    func spawn(pid: pid_t, bundle: URL, stateDirectory: String?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", Self.script, "agterm-live-reset", String(pid), bundle.path, stateDirectory ?? "",
                             open, String(maxWaits)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            Self.logger.error("could not start the relauncher: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
