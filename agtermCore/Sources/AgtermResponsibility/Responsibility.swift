#if canImport(Darwin)
import Darwin
#endif

/// Optional access to macOS process responsibility without a static SPI dependency.
public struct Responsibility: Sendable {
    public static let system = Responsibility()

    public enum SpawnError: Error, Equatable {
        case unavailable
        case invalidArguments
        case systemCall(String, Int32)
    }

    #if canImport(Darwin)
    private typealias SetDisclaim = @convention(c) @Sendable (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ReadResponsible = @convention(c) @Sendable (Int32) -> Int32

    private let setDisclaim: SetDisclaim?
    private let readResponsible: ReadResponsible?

    init(resolveSymbol: (String) -> UnsafeMutableRawPointer?) {
        setDisclaim = resolveSymbol("responsibility_spawnattrs_setdisclaim").map { unsafeBitCast($0, to: SetDisclaim.self) }
        readResponsible = resolveSymbol("responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: ReadResponsible.self) }
    }
    #endif

    public init() {
        #if canImport(Darwin)
        // Darwin's RTLD_DEFAULT searches already-loaded system libraries.
        self.init(resolveSymbol: { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) })
        #endif
    }

    public var isAvailable: Bool {
        #if canImport(Darwin)
        setDisclaim != nil && readResponsible != nil
        #else
        false
        #endif
    }

    public func responsibleProcess(of pid: Int32) -> Int32? {
        #if canImport(Darwin)
        guard pid > 0, let readResponsible else { return nil }
        let responsible = readResponsible(pid)
        return responsible > 0 ? responsible : nil
        #else
        nil
        #endif
    }

    /// `argv` includes argv[0]; `env` replaces the inherited environment.
    public func spawnDisclaimed(executable: String, argv: [String], env: [String: String]) throws -> Int32 {
        #if canImport(Darwin)
        guard isAvailable, let setDisclaim else { throw SpawnError.unavailable }
        guard !argv.isEmpty, !executable.utf8.contains(0), argv.allSatisfy({ !$0.utf8.contains(0) }),
              env.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
        else { throw SpawnError.invalidArguments }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(setDisclaim(&attributes, 1), operation: "responsibility_spawnattrs_setdisclaim")

        var arguments = try Self.copyStrings(argv)
        defer { arguments.forEach { free($0) } }
        var environment = try Self.copyStrings(env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer { environment.forEach { free($0) } }
        var pid: Int32 = 0
        let result = executable.withCString { path in
            arguments.withUnsafeMutableBufferPointer { args in
                environment.withUnsafeMutableBufferPointer { vars in
                    posix_spawn(&pid, path, nil, &attributes, args.baseAddress, vars.baseAddress)
                }
            }
        }
        try Self.check(result, operation: "posix_spawn")
        return pid
        #else
        throw SpawnError.unavailable
        #endif
    }

    #if canImport(Darwin)
    private static func check(_ result: Int32, operation: String) throws {
        guard result == 0 else { throw SpawnError.systemCall(operation, result) }
    }

    private static func copyStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var strings = values.map { strdup($0) }
        guard strings.allSatisfy({ $0 != nil }) else {
            strings.forEach { free($0) }
            throw SpawnError.systemCall("strdup", ENOMEM)
        }
        strings.append(nil)
        return strings
    }
    #endif
}
