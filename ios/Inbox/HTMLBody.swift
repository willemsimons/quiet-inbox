import SwiftUI
import WebKit

/// The email as it really looks: its own HTML in a web view that never scrolls on its own and grows to fit,
/// dark like the Mac reader. The email's scripts never run; links open in Safari.
struct HTMLBody: View {
    let html: String
    @State private var height: CGFloat = 80
    var body: some View {
        HTMLWebView(html: html, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Email")
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        // Runs in the app's own script world, so it works with the email's scripts switched off.
        config.userContentController.addUserScript(WKUserScript(source: Self.fitScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(Self.document(html), baseURL: nil)
    }

    static func document(_ body: String) -> String {
        """
        <!doctype html><html class="flip"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body { margin: 0; background: transparent; overflow: hidden; -webkit-text-size-adjust: 100%; }
          body { padding: 14px 14px; font: 15px/1.55 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; } pre { white-space: pre-wrap; }
          html.flip { background: #fff; color: #202124; filter: invert(.9) hue-rotate(180deg); }
          html.flip a { color: #1a73e8; }
          html.flip img, html.flip picture, html.flip video, html.flip svg, html.flip [style*="background-image"], html.flip [background] { filter: invert(1) hue-rotate(180deg); }
          html.keep { background: transparent; color-scheme: dark; }
          blockquote { margin: 8px 0 0; padding-left: 10px; border-left: 2px solid #dadce0; color: #5f6368; }
          .gmail_quote, blockquote[type=cite], .yahoo_quoted { display: none !important; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// Keeps already-dark emails dark, scales wide emails to the screen, and reports the height as it settles.
    static let fitScript = """
    (() => {
      const lum = el => { const m = getComputedStyle(el).backgroundColor.match(/[\\d.]+/g);
        if (!m || (m[3] !== undefined && +m[3] < .5)) return null; return (.2126*m[0] + .7152*m[1] + .0722*m[2]) / 255; };
      const found = [document.body, ...document.querySelectorAll("body > *, body > * > *, table")].slice(0, 12).map(lum).find(v => v !== null);
      if (found !== undefined && found < .35) document.documentElement.className = "keep";
      const fit = () => {
        document.body.style.zoom = 1;
        const wide = document.documentElement.scrollWidth, room = window.innerWidth;
        if (wide > room + 2) document.body.style.zoom = (room / wide).toFixed(3);
      };
      fit();
      document.querySelectorAll("img").forEach(img => img.complete || img.addEventListener("load", fit, {once: true}));
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loaded: String?
        private var timer: Timer?
        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            measure(view)
            // Images and fonts arrive after load; keep the frame matched for a few seconds.
            var ticks = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self, weak view] t in
                ticks += 1
                guard let self, let view, ticks < 20 else { t.invalidate(); return }
                self.measure(view)
            }
        }

        private func measure(_ view: WKWebView) {
            view.callAsyncJavaScript("return Math.ceil(document.body.getBoundingClientRect().height * (parseFloat(document.body.style.zoom) || 1))",
                                     in: nil, in: .defaultClient) { [weak self] result in
                guard let self, case .success(let value) = result, let h = value as? Double, h > 0 else { return }
                let next = CGFloat(h)
                if abs(next - self.height.wrappedValue) > 1 { self.height.wrappedValue = next }
            }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }
    }
}
