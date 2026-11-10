import Foundation

extension String {
    // written from a child: a write descriptor held here leaks into another test's spawn, and Linux refuses the exec (ETXTBSY)
    func writeExecutable(to url: URL, mode: Int = 0o755) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"printf '%s' "$1" >"$0" && chmod "$2" "$0""#, url.path, self, String(mode, radix: 8)]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}
