import AppKit
import UserNotifications

/// Watches the Inbox server from the Mac side: the Dock badge, notifications for important new mail,
/// and a heads-up when Google's weekly sign-in runs out. Works while the window is closed.
final class Monitor: NSObject, UNUserNotificationCenterDelegate {
    struct Mail: Decodable {
        var a: String
        var gmailId: String
        var unread: Bool
        var score: Int?
        var from: String?
        var subj: String?
        var why: String?
        var key: String { a + ":" + gmailId }
    }
    struct Snapshot: Decodable {
        var mail: [Mail]
        var signedOut: [String]?
    }

    /// Mail ranked at least this important gets a notification when it arrives.
    static let importantScore = 75

    var onOpenMail: ((String, String) -> Void)?
    var onSignedOut: (([String]) -> Void)?

    private let repo: URL
    private var timer: Timer?
    private var seeded = false
    private var known = Set<String>()
    private var warnedSignedOut = Set<String>()

    init(repo: URL) {
        self.repo = repo
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func start() {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
    }

    private var token: String? {
        (try? String(contentsOf: repo.appendingPathComponent(".session-key"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func poll() {
        guard let token else { return }
        var req = URLRequest(url: AppDelegate.home.appendingPathComponent("snapshot"))
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue(token, forHTTPHeaderField: "X-Inbox-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300 // a refresh can take a while when there's new mail to rank
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self, let data else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                DispatchQueue.main.async { self.apply(snap) }
            } else if code == 400, String(decoding: data, as: UTF8.self).contains("No connected accounts") {
                DispatchQueue.main.async { self.signedOut(["Work", "Personal"]) }
            }
        }.resume()
    }

    private func apply(_ snap: Snapshot) {
        let unread = snap.mail.filter(\.unread)
        NSApp.dockTile.badgeLabel = unread.isEmpty ? nil : (unread.count > 999 ? "999+" : "\(unread.count)")

        let fresh = unread.filter { !known.contains($0.key) }
        known.formUnion(snap.mail.map(\.key))
        // The first look after launch only learns what's already there; only mail that arrives later notifies.
        if seeded {
            for m in fresh where (m.score ?? 0) >= Self.importantScore { notify(m) }
        }
        seeded = true

        let out = Set(snap.signedOut ?? [])
        warnedSignedOut.formIntersection(out) // signed back in: warn again next time it expires
        if !out.subtracting(warnedSignedOut).isEmpty { signedOut(Array(out)) }
    }

    private func signedOut(_ names: [String]) {
        warnedSignedOut.formUnion(names)
        onSignedOut?(names.sorted())
    }

    private func notify(_ m: Mail) {
        let content = UNMutableNotificationContent()
        content.title = plain(m.from) ?? "New email"
        content.subtitle = plain(m.subj) ?? ""
        content.body = plain(m.why)?.replacingOccurrences(of: "Picked because ", with: "") ?? ""
        content.sound = .default
        content.threadIdentifier = m.a
        content.userInfo = ["a": m.a, "gmailId": m.gmailId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.key, content: content, trigger: nil))
    }

    /// The server escapes email text for the page; notifications want it plain.
    private func plain(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        var out = s
        for (code, ch) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: code, with: ch)
        }
        return out
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let a = info["a"] as? String, let id = info["gmailId"] as? String {
            DispatchQueue.main.async { self.onOpenMail?(a, id) }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        // While Inbox is in front, the list already shows it.
        done(NSApp.isActive ? [] : [.banner, .sound])
    }
}
