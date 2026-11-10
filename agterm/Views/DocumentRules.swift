import WebKit

/// DocumentRules is the content rule list a document page loads under. It blocks every network load, which the page's
/// CSP cannot do alone: WebKit checks preconnect and DNS-prefetch hints against rule lists only.
@MainActor
final class DocumentRules {
    static let shared = DocumentRules()
    static let unavailable = "the network filter for a clicked html page could not be installed"
    // content-blocker patterns have no alternation, so each scheme gets its own rule
    private static let source = "[" + ["^https?://", "^wss?://", "^ftps?://"]
        .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }.joined(separator: ",") + "]"
    private var compiled: WKContentRuleList?

    /// install puts the rules on `controller`, compiling them on first use; false when WebKit refuses them. Only
    /// document pages carry a rule list, so replacing the controller's lists keeps a reload from stacking them.
    func install(on controller: WKUserContentController) async -> Bool {
        if compiled == nil {
            let list = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "agterm.document", encodedContentRuleList: Self.source)
            compiled = compiled ?? list
        }
        guard let compiled else { return false }
        controller.removeAllContentRuleLists()
        controller.add(compiled)
        return true
    }
}
