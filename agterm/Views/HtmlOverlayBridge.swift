import WebKit
import agtermCore

/// HtmlBridgeDispatch runs one control request for a page, through the same entry point as the control socket.
typealias HtmlBridgeDispatch = @MainActor (ControlRequest) async -> ControlResponse

/// HtmlOverlayBridge lets a file page run agterm commands. agterm's own script turns `data-agterm` tags into
/// requests; it lives in a world of its own, so it runs with the page's JavaScript off and the page cannot
/// replace it, while the DOM it listens on is shared with the page. A `--js` page also gets `agterm.request`
/// in its own world, over a second registration of the same handler.
@MainActor
enum HtmlOverlayBridge {
    static let world = WKContentWorld.world(name: "agterm-bridge")
    static let handlerName = "agterm"

    // submit and click listeners run in the capture phase and cancel the default before anything awaits, so a
    // tagged form never navigates. A button inside a tagged form belongs to the form's submit; a tagged button
    // elsewhere must be type="button", or it would submit an untagged form it sits in as well. A key is refused
    // when it would take two values, because keeping either one silently drops the other.
    static let adapterScript = """
        (() => {
          const handler = window.webkit.messageHandlers.\(handlerName);
          const show = (el, text) => {
            const selector = el.getAttribute('data-agterm-into');
            const into = selector ? document.querySelector(selector) : null;
            if (into) into.textContent = text;
          };
          const shown = (result) => {
            if (result && typeof result.text === 'string') return result.text;
            return JSON.stringify(result ?? {});
          };
          const formArgs = (form, args, submitter) => {
            const seen = new Set();
            for (const control of form.elements) {
              const name = control.name;
              if (!name || control.matches(':disabled')) continue;
              const type = (control.type || '').toLowerCase();
              if (['submit', 'button', 'reset', 'image'].includes(type) && control !== submitter) continue;
              if (type === 'file') throw new Error(`file inputs are not supported: ${name}`);
              if (type === 'radio' && !control.checked) continue;
              let value;
              if (type === 'checkbox') {
                value = control.checked;
              } else if (type === 'number') {
                if (control.value === '') continue;
                value = control.valueAsNumber;
                if (!Number.isFinite(value)) throw new Error(`not a number: ${name}`);
              } else if (control instanceof HTMLSelectElement && control.multiple) {
                const picked = Array.from(control.selectedOptions);
                if (picked.length > 1) throw new Error(`more than one value for ${name}`);
                if (picked.length === 0) continue;
                value = picked[0].value;
              } else {
                value = control.value;
              }
              if (seen.has(name)) throw new Error(`more than one value for ${name}`);
              seen.add(name);
              args[name] = value;
            }
            return args;
          };
          const send = (el, form, submitter) => {
            const body = {cmd: el.getAttribute('data-agterm')};
            const target = el.getAttribute('data-agterm-target');
            if (target !== null) body.target = target;
            try {
              const base = el.getAttribute('data-agterm-args');
              let args = base === null ? undefined : JSON.parse(base);
              if (form) args = formArgs(form, args ?? {}, submitter);
              if (args !== undefined) body.args = args;
            } catch (error) {
              show(el, error.message);
              return;
            }
            handler.postMessage(body).then((result) => show(el, shown(result)), (error) => show(el, error.message));
          };
          document.addEventListener('submit', (event) => {
            const form = event.target;
            if (!(form instanceof HTMLFormElement) || !form.hasAttribute('data-agterm')) return;
            event.preventDefault();
            send(form, form, event.submitter);
          }, true);
          document.addEventListener('click', (event) => {
            const el = event.target instanceof Element ? event.target.closest('[data-agterm]') : null;
            if (!el || el instanceof HTMLFormElement || el.closest('form[data-agterm]')) return;
            if (el instanceof HTMLButtonElement && el.type !== 'button') return;
            event.preventDefault();
            send(el, null, null);
          }, true);
        })();
        """

    // the page's own entry point; the second argument is the request envelope, not the arguments themselves
    static let helperScript = """
        (() => {
          const handler = window.webkit.messageHandlers.\(handlerName);
          const request = (cmd, {target, args} = {}) => {
            const body = {cmd};
            if (target !== undefined) body.target = target;
            if (args !== undefined) body.args = args;
            return handler.postMessage(body);
          };
          Object.defineProperty(window, 'agterm', {value: Object.freeze({request}), enumerable: false});
        })();
        """

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
