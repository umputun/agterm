import Foundation
import Testing
@testable import agtermCore

@MainActor
final class SshConnectionPoolTests {
    private var ran: [[String]] = []
    private var alive: Set<String> = []
    private var startStatus: Int32 = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdStarts = false
    private var holdChecks = false
    private var gateOpen = false

    private func pool(key: String = "window-1") -> SshConnectionPool {
        SshConnectionPool(host: "box", root: "/tmp/agterm-ssh-501", key: key) { [weak self] argv in
            guard let self else { return 255 }
            ran.append(argv)
            let path = argv.joined(separator: " ").components(separatedBy: "ControlPath=").last?
                .components(separatedBy: CharacterSet(charactersIn: " '")).first ?? ""
            if argv.contains("check") {
                if holdChecks, !gateOpen { await withCheckedContinuation { gate = $0 } }
                return alive.contains(path) ? 0 : 255
            }
            if holdStarts, !gateOpen { await withCheckedContinuation { gate = $0 } }
            if startStatus == 0 { alive.insert(path) }
            return startStatus
        }
    }

    private var starts: Int { ran.filter { $0.first == "/bin/sh" }.count }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // bounded by retries, not wall time: the Linux start-of-run scheduling stall outlasts any short deadline
    private func held() async -> Bool {
        for _ in 0..<1000 where gate == nil { await Task.yield() }
        return gate != nil
    }

    private func openGate() {
        gateOpen = true
        gate?.resume()
        gate = nil
    }

    @Test func eightUsersShareAConnectionAndANinthOpensAnother() {
        let pool = pool()

        let paths = (0..<9).map { pool.lease("pane:\($0)") }

        #expect(Set(paths.prefix(8)).count == 1)
        #expect(paths[8] != paths[0])
        #expect(pool.load == [8, 1])
    }

    @Test func aUserKeepsItsSlotAndAReleasedOneFreesRoom() {
        let pool = pool()
        let first = (0..<8).map { pool.lease("pane:\($0)") }[0]

        let again = pool.lease("pane:3")
        pool.release("pane:3")
        let newcomer = pool.lease("present:x")

        #expect(again == first)
        #expect(newcomer == first)
        #expect(pool.load == [8])
    }

    @Test func retainReleasesOnlyTheAbsentUsersOfItsKind() {
        let pool = pool()
        for user in ["pane:a", "pane:b", "present:a", "catalog"] { pool.lease(user) }

        pool.retain(["pane:a"], prefix: "pane:")

        #expect(pool.load == [3])
        #expect(pool.lease("pane:b") == pool.lease("pane:a"))
    }

    @Test func aColdOpenStartsEachConnectionOnceHoweverManyUsersArrive() async {
        let pool = pool()

        for index in 0..<20 {
            pool.lease("pane:\(index)")
            pool.lease("present:\(index)")
        }
        await settle()

        #expect(pool.load == [8, 8, 8, 8, 8])
        #expect(starts == 5)
    }

    @Test func callersArrivingDuringAStartShareIt() async {
        let pool = pool()
        holdStarts = true
        let path = pool.lease("catalog")
        #expect(await held())

        async let first = pool.ready(path)
        async let second = pool.ready(path)
        await settle()
        openGate()
        let results = await [first, second]

        #expect(results == [true, true])
        #expect(starts == 1)
    }

    @Test func aLiveConnectionIsNotStartedAgainAndADeadOneIsReplacedOnce() async {
        let pool = pool()
        let path = pool.lease("catalog")
        await settle()
        pool.lease("pane:a")
        await settle()
        let whileAlive = starts

        alive.remove(path)
        let replaced = await pool.ready(path)

        #expect(whileAlive == 1)
        #expect(replaced)
        #expect(starts == 2)
    }

    @Test func aReattachInAFullSlotWhoseConnectionDiedBringsThatConnectionBack() async {
        let pool = pool()
        let paths = (0..<8).map { pool.lease("pane:\($0)") }
        await settle()
        alive.remove(paths[0])
        let probe = pool.leaseOnce()
        await settle()
        let afterProbe = starts

        let reattach = pool.lease("pane:3")
        await settle()

        #expect(probe.path != paths[0])
        #expect(afterProbe == 2)
        #expect(reattach == paths[0])
        #expect(alive.contains(paths[0]))
        #expect(starts == 3)
    }

    @Test func closingDuringACheckStartsNothing() async {
        let pool = pool()
        holdChecks = true
        let path = pool.lease("catalog")
        #expect(await held())

        _ = pool.close()
        openGate()
        await settle()

        #expect(starts == 0)
        #expect(!alive.contains(path))
    }

    @Test func aConnectionThatFinishesStartingAfterCloseIsEndedAtOnce() async {
        let pool = pool()
        holdStarts = true
        let path = pool.lease("catalog")
        #expect(await held())

        _ = pool.close()
        openGate()
        await settle()

        #expect(starts == 1)
        #expect(ran.last == SshConnectionPool.exitCommand(host: "box", path: path))
    }

    @Test func pagesJobsAndCommandsPastEightOpenAnotherConnection() {
        let pool = pool()
        for index in 0..<3 { pool.lease("page:\(index)") }
        for index in 0..<3 { pool.lease("job:\(index)") }
        let once = (0..<3).map { _ in pool.leaseOnce() }

        pool.release(once[0].user)

        #expect(once[2].path != once[0].path)
        #expect(pool.load == [7, 1])
    }

    @Test func closingDropsEveryLeaseAndEndsEachConnection() async {
        let pool = pool()
        for index in 0..<9 { pool.lease("pane:\(index)") }

        let commands = pool.close()
        let afterClose = await pool.ready(pool.lease("pane:0"))

        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.prefix(3) == ["ssh", "-O", "exit"] })
        #expect(!afterClose)
    }

    @Test func pathsAreShortAndDifferPerOwner() {
        let one = pool(key: "/tmp/a|window-1").lease("x")
        let other = pool(key: "/tmp/b|window-1").lease("x")

        #expect(one != other)
        #expect(one.utf8.count < 60)
        #expect(SshConnectionPool.hash("same") == SshConnectionPool.hash("same"))
    }

    private final class Recorder: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            var sent: [Data] = []
            var stopped = false
            func send(_ line: Data) { sent.append(line) }
            func stop() { stopped = true }
        }
        var opened: [Link] = []

        func open(_: [String], onLine _: @escaping @MainActor (Data) -> Void,
                  onClose _: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            let link = Link()
            opened.append(link)
            return link
        }
    }

    @Test func aPooledStreamOpensOnceItsConnectionAnswersAndKeepsWhatWasSentMeanwhile() async {
        let pool = pool()
        holdStarts = true
        let inner = Recorder()
        let transport = PooledTransport(pool: pool, path: pool.lease("present:a"), inner: inner)

        let link = transport.open(["ssh"], onLine: { _ in }, onClose: { _ in })
        link.send(Data("hello".utf8))
        #expect(await held())
        let beforeConnection = inner.opened.count
        openGate()
        await settle()

        #expect(beforeConnection == 0)
        #expect(inner.opened.count == 1)
        #expect(inner.opened.first?.sent == [Data("hello".utf8)])
    }

    @Test func streamsWaitingOnAConnectionThatCannotStartCloseUnopenedAndOneLaterStartServesThemAll() async {
        let pool = pool()
        startStatus = 255
        let inner = Recorder()
        let transport = PooledTransport(pool: pool, path: pool.lease("present:a"), inner: inner)
        var closed: [String] = []

        for _ in 0..<2 { _ = transport.open(["ssh"], onLine: { _ in }, onClose: { closed.append($0) }) }
        await settle()
        let failedStarts = starts
        startStatus = 0
        for _ in 0..<2 { _ = transport.open(["ssh"], onLine: { _ in }, onClose: { closed.append($0) }) }
        await settle()

        #expect(failedStarts == 1)
        #expect(closed == ["no connection to box", "no connection to box"])
        #expect(inner.opened.count == 2)
        #expect(starts == 2)
    }

    @Test func aPooledStreamStoppedBeforeItsConnectionNeverOpens() async {
        let pool = pool()
        holdStarts = true
        let inner = Recorder()
        let transport = PooledTransport(pool: pool, path: pool.lease("present:a"), inner: inner)

        let link = transport.open(["ssh"], onLine: { _ in }, onClose: { _ in })
        link.stop()
        await settle()
        openGate()
        await settle()

        #expect(inner.opened.isEmpty)
    }

    @Test func theConnectionStartsDetachedFromTheRunnersPipes() {
        let command = SshConnectionPool.startCommand(host: "box", path: "/tmp/p-0")

        #expect(command.prefix(2) == ["/bin/sh", "-c"])
        #expect(command[2].hasSuffix(" </dev/null >/dev/null 2>&1"))
        #expect(command[2].contains("ControlPersist=60"))
        #expect(command[2].contains("'-f' '-N' '-M'"))
    }

    // regression: a killed master leaves its socket, and ssh -M then runs without multiplexing
    @Test func aStartRemovesTheSocketADeadConnectionLeft() {
        let command = SshConnectionPool.startCommand(host: "box", path: "/tmp/p-0")

        #expect(command[2].hasPrefix("rm -f '/tmp/p-0'; "))
        #expect(command[2].components(separatedBy: "; exec ").count == 2)
    }

    // regression: panes joined to a master ignore their own keepalive, so a master without one never notices a dead link
    @Test(arguments: zip(["serveraliveinterval 0", "serveraliveinterval 15", ""], [true, false, false]))
    func theSharedConnectionGetsKeepAliveOnlyWhenTheUsersConfigSetsNone(config: String, added: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pool-keepalive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        if [ "$1" = -G ]; then printf '%s\\n' '\(config)'; fi
        """.writeExecutable(to: directory.appendingPathComponent("ssh"))
        let command = SshConnectionPool.startCommand(host: "box", path: directory.appendingPathComponent("p-0").path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls.count == 2)
        #expect(calls.first?.hasPrefix("-G -N -o BatchMode=yes") == true, "the check sees the master's own options")
        #expect(calls.last?.hasPrefix("-f -N -M") == true)
        #expect(calls.last?.contains("-o ServerAliveInterval=5 -o ServerAliveCountMax=2 box") == added)
    }

    // regression: a check without -N reads a `Match sessiontype` block for another session type than the master's
    @Test func theKeepAliveCheckAnswersForTheSharedConnectionsSessionType() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pool-sessiontype-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        if [ "$1" = -G ]; then
          case " $* " in *" -N "*) echo 'serveraliveinterval 0' ;; *) echo 'serveraliveinterval 15' ;; esac
        fi
        """.writeExecutable(to: directory.appendingPathComponent("ssh"))
        let command = SshConnectionPool.startCommand(host: "box", path: directory.appendingPathComponent("p-0").path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls.last?.contains("-o ServerAliveInterval=5 -o ServerAliveCountMax=2 box") == true)
    }
}
