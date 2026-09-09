import Darwin
import Foundation
import agtermCore

enum HostIdentity {
    static func read(pid: Int32) throws -> SessionHost.Hello {
        let path = try executablePath(pid: pid)
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension.lowercased() == "app" {
                let data = try Data(contentsOf: directory.appendingPathComponent("Contents/Info.plist"))
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                guard let info = plist as? [String: Any], let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else {
                    throw HostFailure.invalidIdentity
                }
                return .init(bundleID: id, bundlePath: directory.path, pid: pid)
            }
            directory.deleteLastPathComponent()
        }
        throw HostFailure.invalidIdentity
    }

    static func executablePath(pid: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { throw HostFailure.invalidIdentity }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return canonical(path)
    }

    static func peer(fd: Int32) throws -> SessionHost.Hello {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw HostFailure.invalidIdentity }
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { throw HostFailure.invalidIdentity }
        return try read(pid: pid)
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
