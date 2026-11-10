import Foundation
import Testing
@testable import agtermCore

struct ForwardedPageTests {
    @Test(arguments: [
        ("https://localhost:8443/app?x=1#top", "localhost", 8443, "localhost:5001:localhost:8443", "https://localhost:5001/app?x=1#top"),
        ("http://127.0.0.1/", "127.0.0.1", 80, "127.0.0.1:5001:127.0.0.1:80", "http://127.0.0.1:5001/"),
        ("https://localhost/", "localhost", 443, "localhost:5001:localhost:443", "https://localhost:5001/"),
        ("http://[::1]:3000/a", "::1", 3000, "[::1]:5001:[::1]:3000", "http://[::1]:5001/a"),
    ])
    func aLoopbackPageKeepsItsHostAndTakesTheLocalPort(_ text: String, host: String, port: Int, spec: String, local: String) throws {
        let page = try #require(ForwardedPage(text))

        #expect(page.host == host)
        #expect(page.port == port)
        #expect(page.spec(localPort: 5001) == spec)
        #expect(page.url(localPort: 5001)?.absoluteString == local)
    }

    @Test(arguments: ["https://example.com/", "file:///tmp/x.html", "http://10.0.0.1:8080/", "not a url"])
    func aPageOffTheLoopbackIsNotForwarded(_ text: String) {
        #expect(ForwardedPage(text) == nil)
    }
}
