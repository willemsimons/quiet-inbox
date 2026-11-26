import AppKit
import WebKit
import ServiceManagement

/// Inbox for the Mac: a native window around the local Inbox server (inbox.py).
/// The app starts the server if it isn't already running, shows the page, and stops the server it started on quit.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let port = 8765
    static let home = URL(string: "http://127.0.0.1:\(port)/")!

    private var window: NSWindow!
    private var web: WKWebView!
    private var status: NSTextField!
    private var server: Process?
    private var waited = 0
    private var monitor: Monitor?
    private let pageRunner = PageRunner(inboxPort: AppDelegate.port)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// The Inbox folder (holds inbox.py). Set at build time; the app is only for this Mac.
    private var repo: URL {
        let path = Bundle.main.object(forInfoDictionaryKey: "InboxRepo") as? String ?? ""
        return URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() + "/inbox-app" : path)
    }
    private var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Inbox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("server.log")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // The Dock otherwise shows whatever icon macOS cached, and may frame a see-through icon in a gray square.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        buildWindow()
        serverIsUp { up in
            if up { self.load() } else { self.startServer() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        server?.terminate()
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Inbox"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 520)
        window.backgroundColor = NSColor(srgbRed: 0.22, green: 0.31, blue: 0.52, alpha: 1)
        window.setFrameAutosaveName("InboxMain")
        if !window.setFrameUsingName("InboxMain") { window.center() }
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Make room for the window's buttons; the strip above the page drags the window.
        // The glass and sidebar run to the top edge; only their contents move down, clear of the window buttons.
        let css = ".mac-app .sidebar { padding-top: 40px; border-top-right-radius: 0; } .mac-app .main { padding-top: 28px; }"
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('mac-app');" +
                "const s=document.createElement('style');s.textContent=\(String(reflecting: css));document.head.appendChild(s);",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        // The page drives a small browser window through this (unsubscribing from senders).
        config.userContentController.addScriptMessageHandler(pageRunner, contentWorld: .page, name: "browse")

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = false
        web.isHidden = true
        // Trackpad pinch zooms the calendar's hours (the page decides whether the calendar is showing).
        web.addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:))))

        status = NSTextField(labelWithString: "Opening your inbox…")
        status.font = .systemFont(ofSize: 15, weight: .medium)
        status.textColor = NSColor(white: 1, alpha: 0.75)
        status.alignment = .center
        status.maximumNumberOfLines = 0

        let root = NSView()
        let drag = DragStrip()
        for v in [web!, status!, drag] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            drag.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            drag.topAnchor.constraint(equalTo: root.topAnchor),
            drag.heightAnchor.constraint(equalToConstant: 28),
            status.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -80),
        ])
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    private func show(_ message: String) {
        status.stringValue = message
        status.isHidden = false
        web.isHidden = true
    }

    private func load() {
        web.load(URLRequest(url: Self.home))
        if monitor == nil {
            let m = Monitor(repo: repo)
            m.onOpenMail = { [weak self] a, id in self?.open(account: a, gmailID: id) }
            m.onSignedOut = { [weak self] names in self?.askToSignIn(names) }
            monitor = m
            m.start()
        }
    }

    /// From a notification: bring Inbox forward with that email open in the reading pane.
    private func open(account: String, gmailID: String) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let js = """
        (() => { const m = mail.find(x => x.a === \(String(reflecting: account)) && x.gmailId === \(String(reflecting: gmailID)));
          if (!m) return false; view = "mail"; acct = "all"; if (!shown().some(x => x.id === m.id)) cat = "";
          sel = m.id; peek = true; render(); return true; })()
        """
        web.evaluateJavaScript(js) { [weak self] result, _ in
            // Not in this copy of the page yet (it just arrived): reload, then try once more.
            if (result as? Bool) != true {
                self?.afterLoad = { self?.web.evaluateJavaScript(js) }
                self?.web.reload()
            }
        }
    }
    private var afterLoad: (() -> Void)?

    private var askingSignIn = false
    private func askToSignIn(_ names: [String]) {
        guard !askingSignIn else { return }
        askingSignIn = true
        let alert = NSAlert()
        alert.messageText = names.count > 1 ? "Google signed out \(names.joined(separator: " and "))" : "Google signed out \(names[0])"
        alert.informativeText = "Google asks Inbox to sign in again each week. Until then, that inbox won't get new mail."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Later")
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { [weak self] answer in
            self?.askingSignIn = false
            if answer == .alertFirstButtonReturn { self?.signIn() }
        }
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    // MARK: Server

    private func serverIsUp(_ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: Self.home)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let up = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(up) }
        }.resume()
    }

    /// Apps opened from Finder get a bare PATH; Inbox needs python3 and the claude command (for ranking).
    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       env["PATH"] ?? ""].joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func python(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-u", repo.appendingPathComponent("inbox.py").path] + args
        p.currentDirectoryURL = repo
        p.environment = environment
        return p
    }

    private func startServer() {
        show("Opening your inbox…\nFetching new mail and ranking it.")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        let p = python(["serve"])
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.server === proc else { return }
                self.server = nil
                self.show("Inbox stopped.\n\n\(self.lastLog())\n\nUse File ▸ Restart Inbox to try again.")
            }
        }
        do {
            try p.run()
            server = p
            waited = 0
            waitForServer()
        } catch {
            show("Couldn't start Inbox: \(error.localizedDescription)")
        }
    }

    private func waitForServer() {
        serverIsUp { up in
            if up { return self.load() }
            guard self.server != nil else { return }
            self.waited += 1
            if self.waited % 10 == 0 { self.show("Opening your inbox…\n\(self.lastLog())") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitForServer() }
        }
    }

    private func lastLog() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    @objc private func restartServer() {
        if let p = server {
            server = nil
            p.terminationHandler = nil
            p.terminate()
            p.waitUntilExit()
            startServer()
        } else {
            // Someone else's server (started from Terminal). Reload it rather than stopping it.
            serverIsUp { up in up ? self.load() : self.startServer() }
        }
    }

    /// Google signs this personal app out every week. This runs the sign-in for both accounts in the browser.
    @objc private func signIn() {
        let p = python(["login"])
        p.standardOutput = try? FileHandle(forWritingTo: logURL)
        p.standardError = p.standardOutput
        p.terminationHandler = { _ in DispatchQueue.main.async { self.load(); self.monitor?.poll() } }
        try? p.run()
    }

    private var lastMagnification: CGFloat = 0
    @objc private func pinched(_ g: NSMagnificationGestureRecognizer) {
        if g.state == .began { lastMagnification = 0 }
        let step = g.magnification - lastMagnification
        lastMagnification = g.magnification
        guard g.state == .changed || g.state == .ended, abs(step) > 0.0001 else { return }
        let p = g.location(in: web)
        let y = web.isFlipped ? p.y : web.bounds.height - p.y // the page measures from the top
        web.evaluateJavaScript("window.calPinch?.(\(1 + step), \(y))")
    }

    @objc private func reload() { if web.isHidden { restartServer() } else { web.reload() } }
    @objc private func openInBrowser() { NSWorkspace.shared.open(Self.home) }
    @objc private func showLog() { NSWorkspace.shared.open(logURL) }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let action, responds(to: action) { i.target = self }
            return i
        }
        menu("Inbox", [
            item("About Inbox", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            {
                let i = item("Open at Login", #selector(toggleOpenAtLogin(_:)))
                i.state = SMAppService.mainApp.status == .enabled ? .on : .off
                return i
            }(),
            .separator(),
            item("Hide Inbox", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Inbox", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("Sign In to Google Again…", #selector(signIn)),
            item("Restart Inbox", #selector(restartServer), "r", [.command, .shift]),
            item("Open in Browser", #selector(openInBrowser)),
            item("Show Log", #selector(showLog)),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("View", [
            item("Reload", #selector(reload), "r"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.mainMenu = main
    }
}

// MARK: Web view behavior

extension AppDelegate: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private func isInbox(_ url: URL?) -> Bool {
        guard let url else { return true }
        if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" { return true }
        return (url.host == "127.0.0.1" || url.host == "localhost") && url.port == Self.port
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        // Links in emails open in the default browser; Inbox itself stays in the window.
        if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true, !isInbox(action.request.url) {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType ? .download : .allow)
    }

    // target=_blank links (every link inside an email).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInbox(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.isHidden = true
        web.isHidden = false
        afterLoad?()
        afterLoad = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        show("Couldn't reach Inbox. Use File ▸ Restart Inbox.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    // Attachments go to Downloads and open, like a browser would.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
        var target = folder.appendingPathComponent(suggestedFilename)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        pending[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = pending.removeValue(forKey: ObjectIdentifier(download)) { NSWorkspace.shared.open(url) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pending.removeValue(forKey: ObjectIdentifier(download))
    }
}

private var pending: [ObjectIdentifier: URL] = [:]

/// The strip above the page: drags the window, double-click zooms it, like a title bar.
final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}
