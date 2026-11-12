import Darwin
import Foundation
import MachO
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
        try read(pid: peerPID(fd: fd))
    }

    /// peerPID is the socket peer's pid once it runs as this user, read from the kernel and not from its image.
    static func peerPID(fd: Int32) throws -> Int32 {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw HostFailure.invalidIdentity }
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { throw HostFailure.invalidIdentity }
        return pid
    }

    /// endpointKey is this process's own. The image is the one loaded, not the file on disk, which an
    /// update replaces under a running host.
    static func endpointKey() throws -> String {
        guard let uuid = loadedImageUUID() else { throw HostFailure.invalidIdentity }
        var info = auditinfo_addr_t()
        try hostCheck(getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr_t>.size)))
        return SessionHost.endpointKey(imageUUID: uuid, auditSession: info.ai_asid)
    }

    private static func loadedImageUUID() -> UUID? {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) { return UUID(uuid: command.load(as: uuid_command.self).uuid) }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
