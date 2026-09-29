import WebKit
import agtermCore

/// HtmlBridgeDispatch runs one control request for a page, through the same entry point as the control socket.
typealias HtmlBridgeDispatch = @MainActor (ControlRequest) async -> ControlResponse

/// HtmlOverlayBridge lets a file page run agterm commands. agterm's own script turns `data-agterm` tags into
/// requests; it lives in a world of its own, so it runs with the page's JavaScript off and the page cannot
/// replace it, while the DOM it listens on is shared with the page.
@MainActor
enum HtmlOverlayBridge {
    static let world = WKContentWorld.world(name: "agterm-bridge")
    static let handlerName = "agterm"

    // submit and click listeners run in the capture phase and cancel the default before anything awaits, so a
    // tagged form never navigates. A button inside a tagged form belongs to the form's submit; a tagged button
    // elsewhere must be type="button", or it would submit an untagged form it sits in as well.
    static let adapterScript = """
        (() => {
          const handler = window.webkit.messageHandlers.\(handlerName);
          const send = (el) => {
            const body = {cmd: el.getAttribute('data-agterm')};
            const target = el.getAttribute('data-agterm-target');
            if (target !== null) body.target = target;
            const args = el.getAttribute('data-agterm-args');
            if (args !== null) {
              try { body.args = JSON.parse(args); } catch (e) { return; }
            }
            handler.postMessage(body).catch(() => {});
          };
          document.addEventListener('submit', (event) => {
            const form = event.target;
            if (!(form instanceof HTMLFormElement) || !form.hasAttribute('data-agterm')) return;
            event.preventDefault();
            send(form);
          }, true);
          document.addEventListener('click', (event) => {
            const el = event.target instanceof Element ? event.target.closest('[data-agterm]') : null;
            if (!el || el instanceof HTMLFormElement || el.closest('form[data-agterm]')) return;
            if (el instanceof HTMLButtonElement && el.type !== 'button') return;
            event.preventDefault();
            send(el);
          }, true);
        })();
        """

    /// request decodes a page message into the socket's request shape, nil when it is not one.
    static func request(from body: Any) -> ControlRequest? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(ControlRequest.self, from: data)
    }

    /// reply shapes a response for the page: the result as a JSON object, or the error for a refused request.
    static func reply(_ response: ControlResponse) -> (Any?, String?) {
        guard response.ok else { return (nil, response.error ?? "request failed") }
        guard let result = response.result, let data = try? JSONEncoder().encode(result),
              let object = try? JSONSerialization.jsonObject(with: data) else { return ([String: Any](), nil) }
        return (object, nil)
    }
}

/// HtmlOverlayBridgeHandler receives a page's requests. WebKit keeps it strongly for the page's lifetime, so it
/// holds the page weakly and answers nothing once the page is gone.
@MainActor
final class HtmlOverlayBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var page: HtmlOverlayPage?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let page else { return replyHandler(nil, "page closed") }
        page.handleBridgeRequest(message.body, mainFrame: message.frameInfo.isMainFrame, reply: replyHandler)
    }
}
