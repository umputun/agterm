import Foundation
import agtermCore

extension ControlServer {
    /// textFileRefusal reads and validates the file on the calling thread, nil when the page can open.
    func textFileRefusal(_ path: String) -> ControlResponse? {
        guard case .failure(let failure) = TextProbe.check(path: path) else { return nil }
        return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
    }
}
