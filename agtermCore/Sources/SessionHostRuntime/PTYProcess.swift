import Darwin
import SessionHostTrampoline

/// The parent owns these descriptors and must reap `pid`.
struct PTYProcess: Sendable {
    let pid: Int32
    let ptyFD: Int32
    let execErrorFD: Int32

    enum SpawnError: Error, Equatable {
        case invalidArguments
        case systemCall(Int32)
    }

    static func spawn(argv: [String], env: [String: String], cwd: String, rows: UInt16, cols: UInt16) throws -> PTYProcess {
        guard !argv.isEmpty, !cwd.utf8.contains(0), argv.allSatisfy({ !$0.utf8.contains(0) }),
              env.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
        else { throw SpawnError.invalidArguments }

        var arguments = try copyStrings(argv)
        defer { arguments.forEach { free($0) } }
        var environment = try copyStrings(env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer { environment.forEach { free($0) } }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var ptyFD: Int32 = -1
        var errorFD: Int32 = -1
        var failure: Int32 = 0
        let pid = cwd.withCString { directory in
            arguments.withUnsafeMutableBufferPointer { args in
                environment.withUnsafeMutableBufferPointer { vars in
                    let child = sh_forkpty_exec(args.baseAddress, vars.baseAddress, directory, &size, &ptyFD, &errorFD)
                    if child < 0 { failure = errno }
                    return child
                }
            }
        }
        guard pid > 0 else { throw SpawnError.systemCall(failure) }
        return PTYProcess(pid: pid, ptyFD: ptyFD, execErrorFD: errorFD)
    }

    private static func copyStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var strings = values.map { strdup($0) }
        guard strings.allSatisfy({ $0 != nil }) else {
            strings.forEach { free($0) }
            throw SpawnError.systemCall(ENOMEM)
        }
        strings.append(nil)
        return strings
    }
}
