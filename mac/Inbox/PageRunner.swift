import AppKit
import WebKit

/// A small browser window the Inbox page can drive, a step at a time, for chores on other sites (unsubscribing).
/// The page sends {cmd: "open", url, title}, {cmd: "act", action}, {cmd: "show"} or {cmd: "close"} and gets back
/// what the page now shows: its address, title, visible text and numbered buttons, links and fields.
/// It keeps its own throwaway cookies, separate from everything else.
final class PageRunner: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    private let inboxPort: Int
    private var window: NSWindow?
    private var web: WKWebView?

    init(inboxPort: Int) { self.inboxPort = inboxPort }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Only Inbox's own page may drive it, never an email shown inside it.
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.host == "127.0.0.1", origin.port == inboxPort,
              let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return replyHandler(nil, "Not allowed.")
        }
        switch cmd {
        case "open":
            guard let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") else {
                return replyHandler(nil, "Not a web page.")
            }
            open(url, title: body["title"] as? String ?? "Unsubscribing")
            settle { self.snapshot { replyHandler(["page": $0], nil) } }
        case "act":
            guard let web, let action = body["action"] as? [String: Any] else { return replyHandler(nil, "No page is open.") }
            web.callAsyncJavaScript(Self.actJS, arguments: ["a": action], in: nil, in: .page) { result in
                let outcome = (try? result.get()) as? String ?? "failed"
                self.settle(after: 1.2) { self.snapshot { replyHandler(["result": outcome, "page": $0], nil) } }
            }
        case "show":
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            replyHandler(true, nil)
        case "close":
            // A moment on the confirmation, then away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.window?.close(); self.window = nil; self.web = nil }
            replyHandler(true, nil)
        default:
            replyHandler(nil, "Unknown command.")
        }
    }

    private func open(_ url: URL, title: String) {
        if window == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = self
            web.uiDelegate = self
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.center()
            self.window = window
            self.web = web
        }
        window?.title = title
        // Shown but not focused, so it works alongside you; "show" brings it forward when it needs you.
        window?.orderFront(nil)
        web?.load(URLRequest(url: url))
    }

    /// Wait for the page to finish loading (or give up after 20s), then a beat for scripts to draw it.
    private func settle(after delay: Double = 0.3, waited: Double = 0, _ done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let web = self.web, web.isLoading, waited < 20 {
                self.settle(after: 0.25, waited: waited + delay, done)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done)
            }
        }
    }

    private func snapshot(_ done: @escaping (Any) -> Void) {
        guard let web else { return done(["url": "", "title": "", "text": "", "els": []]) }
        web.callAsyncJavaScript(Self.snapshotJS, arguments: [:], in: nil, in: .page) { result in
            done((try? result.get()) ?? ["url": web.url?.absoluteString ?? "", "title": "", "text": "", "els": []])
        }
    }

    // Pop-ups open in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    private static let snapshotJS = """
    document.querySelectorAll("[data-inbox-i]").forEach(el => el.removeAttribute("data-inbox-i"));
    const shown = el => { const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none"; };
    const labelOf = el => {
      const own = el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      return (el.getAttribute("aria-label") || (own && own.innerText) || el.closest("label")?.innerText || el.innerText
              || el.value || el.placeholder || el.name || el.title || "").trim().replace(/\\s+/g, " ").slice(0, 100);
    };
    const els = [...document.querySelectorAll('a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=checkbox], [role=radio], [role=switch], [role=link], [onclick]')]
      .filter(shown).slice(0, 160);
    return {
      url: location.href, title: document.title,
      text: (document.body?.innerText || "").replace(/\\n{3,}/g, "\\n\\n").slice(0, 6000),
      els: els.map((el, i) => {
        el.setAttribute("data-inbox-i", i);
        const out = {i, tag: el.tagName.toLowerCase(), type: el.type || el.getAttribute("role") || "", text: labelOf(el)};
        if (el.type === "checkbox" || el.type === "radio") out.checked = el.checked;
        else if (el.getAttribute("aria-checked")) out.checked = el.getAttribute("aria-checked") === "true";
        if (el.tagName === "SELECT") out.options = [...el.options].map(o => o.text.trim()).slice(0, 30);
        if (el.tagName === "INPUT" && !["checkbox", "radio", "submit", "button"].includes(el.type)) out.value = el.value;
        return out;
      }),
    };
    """

    private static let actJS = """
    const el = document.querySelector(`[data-inbox-i="${a.i}"]`);
    if (!el) return "That element is gone.";
    el.scrollIntoView({block: "center"});
    if (a.do === "click") { el.click(); return "clicked"; }
    if (a.do === "fill") {
      el.focus();
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), "value")?.set;
      setter ? setter.call(el, a.value ?? "") : (el.value = a.value ?? "");
      el.dispatchEvent(new Event("input", {bubbles: true}));
      el.dispatchEvent(new Event("change", {bubbles: true}));
      return "filled";
    }
    if (a.do === "select") {
      const want = String(a.value || "").toLowerCase();
      const opt = [...(el.options || [])].find(o => o.text.trim().toLowerCase() === want) || [...(el.options || [])].find(o => o.text.toLowerCase().includes(want));
      if (!opt) return "No such option.";
      el.value = opt.value;
      el.dispatchEvent(new Event("change", {bubbles: true}));
      return "selected";
    }
    return "Unknown action.";
    """
}
