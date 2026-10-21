import Foundation
import WebKit
import agtermCore

/// HtmlPageResource is one resource a page source answers: its MIME type and its body in chunks.
struct HtmlPageResource: Sendable {
    let mimeType: String
    let chunks: AsyncThrowingStream<Data, Error>
}

/// HtmlPageSchemeHandler serves `agterm-page://<page-id>/<path>` for one page from an async source, so a
/// page whose files live on another Mac loads through WebKit as if they were local.
/// A request naming another page id, or another scheme, fails without reaching the source.
@MainActor
final class HtmlPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = HtmlSource.replicaScheme

    typealias Source = @Sendable (_ path: String) async throws -> HtmlPageResource

    private let host: String
    private let source: Source
    // keyed by task identity, which WebKit can reuse once a task is gone, so each entry carries a token
    private var running: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]

    init(pageID: UUID, source: @escaping Source) {
        host = pageID.uuidString.lowercased()
        self.source = source
    }

    /// url is the address a page loads `path` from.
    static func url(pageID: UUID, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pageID.uuidString.lowercased()
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        guard let url = task.request.url, url.scheme == Self.scheme, url.host?.lowercased() == host else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let source = source
        let token = UUID()
        // runs on the main actor, as `stop` does: a stopped task is never called again, which WebKit
        // answers with an exception
        let work = Task { [weak self] in
            defer { self?.finished(key, token: token) }
            do {
                let resource = try await source(url.path)
                guard !Task.isCancelled else { return }
                task.didReceive(Self.response(url: url, mimeType: resource.mimeType))
                for try await chunk in resource.chunks {
                    guard !Task.isCancelled else { return }
                    task.didReceive(chunk)
                }
                guard !Task.isCancelled else { return }
                task.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                task.didFailWithError(error)
            }
        }
        running[key] = (token, work)
    }

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.task.cancel()
    }

    private func finished(_ key: ObjectIdentifier, token: UUID) {
        if running[key]?.token == token { running[key] = nil }
    }

    private static func response(url: URL, mimeType: String) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": mimeType]) ?? URLResponse(url: url, mimeType: mimeType,
                                                                                expectedContentLength: -1,
                                                                                textEncodingName: nil)
    }
}
