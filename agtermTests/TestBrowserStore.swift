import WebKit
@testable import agterm
import agtermCore

/// TestBrowserStore removes the WebKit profile a test created. WebKit keeps an identified store outside the
/// state directory, so deleting the directory alone leaves one behind per run.
@MainActor
enum TestBrowserStore {
    /// remove drops the registry's hold on the store, then removes the profile's data if it has an id.
    static func remove(_ profile: BrowserProfile) async throws {
        HtmlOverlayRegistry.shared.profile = nil
        guard let id = try profile.existingIdentifier() else { return }
        // the web content process lets go of a store a moment after its last page closes
        let deadline = Date().addingTimeInterval(10)
        while true {
            do {
                return try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
