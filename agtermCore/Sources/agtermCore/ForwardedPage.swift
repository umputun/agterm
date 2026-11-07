import Foundation

/// ForwardedPage is a headless origin's loopback URL page as this Mac reaches it: the forward targets the origin's
/// host and port, and the URL keeps its host and changes only the port, so TLS checks the name the page was opened
/// with. The local listener binds that same host.
public struct ForwardedPage: Equatable, Sendable {
    /// host is the URL's loopback host: `localhost`, `127.0.0.1` or `::1`.
    public let host: String
    public let port: Int
    private let components: URLComponents

    public init?(_ text: String) {
        guard HtmlSource.isLoopback(text), let url = HtmlSource.webURL(text), let host = HtmlOrigin(url)?.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        self.host = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
        self.components = components
    }

    /// spec is the `-L` argument forwarding `localPort` on this Mac to the page's port on the origin.
    public func spec(localPort: Int) -> String {
        let address = host.contains(":") ? "[\(host)]" : host
        return "\(address):\(localPort):\(address):\(port)"
    }

    /// url is the page's URL at `localPort` on this Mac.
    public func url(localPort: Int) -> URL? {
        var local = components
        local.port = localPort
        return local.url
    }
}
