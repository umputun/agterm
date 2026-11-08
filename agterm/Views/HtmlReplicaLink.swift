import Foundation
import agtermCore

/// HtmlReplicaRevision is the load a replica page shows, read when its file answers arrive.
@MainActor
final class HtmlReplicaRevision {
    var value = 0
}

/// HtmlReplicaLink is how a page shown for another Mac reaches that Mac: `fetch` its files, for the load
/// `HtmlReplicaRevision` names, and `bridge` a file page's requests, answered with the reply JSON text that Mac sent.
struct HtmlReplicaLink {
    /// ownPageCommandsLocal keeps a page's reload and navigation of itself on this Mac: a page companion's viewers each
    /// show their own copy, so those act on the copy that asked.
    var ownPageCommandsLocal = false
    let fetch: @MainActor @Sendable (_ path: String, _ revision: HtmlReplicaRevision) async throws -> HtmlPageResource
    let bridge: @MainActor @Sendable (_ request: Data) async throws -> String

    /// ReadFailure is why `read` returned no bytes, worded for the page's error panel.
    struct ReadFailure: Error {
        let message: String
    }

    /// read collects one file of the other Mac. Reading stops once the bytes pass `limit`, and the dropped stream
    /// cancels the transfer there; a refusal keeps the reason the other Mac gave, and `local` words every other
    /// failure as the local probe would.
    @MainActor func read(_ path: String, revision: HtmlReplicaRevision, limit: Int,
                         local: (tooLarge: String, unreadable: String)) async -> Result<Data, ReadFailure> {
        var data = Data()
        do {
            let resource = try await fetch(path, revision)
            for try await chunk in resource.chunks {
                data.append(chunk)
                if data.count > limit { return .failure(ReadFailure(message: local.tooLarge)) }
            }
        } catch RemotePageChannel.Failure.refused(let reason) {
            return .failure(ReadFailure(message: "\(reason): \(path)"))
        } catch {
            return .failure(ReadFailure(message: local.unreadable))
        }
        return .success(data)
    }
}
