import Foundation
import agtermCore

/// HostRetirement asks every host endpoint under a socket directory, except the one this build and login
/// session create through, to stop. It only connects: a host still rooting a live daemon refuses and stays.
public enum HostRetirement {
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        case stopped
        case refused(String)
        case absent
        case failed(String)

        public var description: String {
            switch self {
            case .stopped: "stopped"
            case .refused(let reason): "refused: \(reason)"
            case .absent: "absent"
            case .failed(let reason): "failed: \(reason)"
            }
        }
    }

    public static func run(socketDirectory: String) throws -> [(endpoint: String, outcome: Outcome)] {
        let own = try SessionHost.endpointName(key: HostIdentity.endpointKey())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: socketDirectory)) ?? []
        return try names.sorted().filter { $0 != own && SessionHost.isEndpointName($0) }.map { name in
            let paths = try SessionHost.paths(socketDirectory: socketDirectory, endpoint: name)
            return (name, stop(paths: paths, socketDirectory: socketDirectory))
        }
    }

    private static func stop(paths: SessionHost.Paths, socketDirectory: String) -> Outcome {
        do {
            let connector = try ClientConnector(paths: paths, socketDirectory: socketDirectory, environment: [:],
                                                startupTimeout: 2, queueTimeout: 5)
            guard let reply = try connector.stopExisting(replyTimeout: 15) else { return .absent }
            switch reply {
            case .stopped: return .stopped
            case .error(let failure): return .refused(failure.message)
            case .hello, .ok: return .failed("unexpected reply")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
}
