import Foundation

@MainActor final class InboxStore: ObservableObject {
    @Published var mail: [Mail] = []
    @Published var events: [CalendarEvent] = []
    @Published var refreshing = false
    @Published var pending: Set<String> = []
    @Published var error: String?
    @Published var syncNote: String?
    @Published var lastSync: Date?
    @Published var demo = false
    let session: GoogleSession
    let api: GoogleAPI
    private var generation = 0
    init(session: GoogleSession) { self.session = session; api = GoogleAPI(session: session) }
    var accounts: [MailAccount] { demo ? [MailAccount(id: "demo@work.example", name: "Work"), MailAccount(id: "demo@example.com", name: "Personal")] : session.accounts }
    func refresh() async {
        guard !demo, !refreshing, pending.isEmpty else { return }
        refreshing = true
        let version = generation
        defer { refreshing = false }
        var notes: [String] = [], loadedMail = mail, loadedEvents = events
        let accounts = session.accounts
        for account in accounts {
            do {
                var fetched = try await api.inbox(account.id)
                do {
                    let ranks = try await api.rankings(account.id)
                    for i in fetched.indices {
                        if let rank = ranks[fetched[i].gmailID] {
                            fetched[i].score = rank.score; fetched[i].category = rank.cat ?? fetched[i].category
                            fetched[i].reason = rank.why ?? fetched[i].reason
                        }
                    }
                    if ranks.isEmpty { notes.append("\(account.name): waiting for rankings from the Mac.") }
                } catch { notes.append("\(account.name): rankings unavailable; using Gmail labels.") }
                loadedMail.removeAll { $0.account == account.id }; loadedMail += fetched
            } catch { notes.append("\(account.name) mail: \(error.localizedDescription)") }
            do {
                let fetched = try await api.events(account.id)
                loadedEvents.removeAll { $0.account == account.id }; loadedEvents += fetched
            } catch { notes.append("\(account.name) calendar: \(error.localizedDescription)") }
        }
        // A refresh that started before a mutation may contain stale labels. Discard it.
        guard version == generation, !demo else { return }
        let connected = Set(session.accounts.map(\.id))
        mail = loadedMail.filter { connected.contains($0.account) }; events = loadedEvents.filter { connected.contains($0.account) }
        lastSync = notes.contains(where: { $0.contains("mail:") || $0.contains("calendar:") }) ? lastSync : Date()
        syncNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
    func flag(_ item: Mail, label: String, value: Bool) async {
        guard !pending.contains(item.id) else { return }
        generation += 1; pending.insert(item.id)
        defer { pending.remove(item.id) }
        do {
            if !demo { try await api.flags(item, label: label, value: value) }
            if let index = mail.firstIndex(where: { $0.id == item.id }) {
                if label == "UNREAD" { mail[index].unread = value }
                if label == "STARRED" { mail[index].starred = value }
            }
        } catch { self.error = error.localizedDescription }
    }
    func trash(_ item: Mail) async -> Bool {
        guard !pending.contains(item.id) else { return false }
        generation += 1; pending.insert(item.id)
        defer { pending.remove(item.id) }
        do {
            if !demo { try await api.trash(item) }
            mail.removeAll { $0.id == item.id }; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func disconnect(_ account: MailAccount) {
        generation += 1; session.remove(account)
        mail.removeAll { $0.account == account.id }; events.removeAll { $0.account == account.id }
    }
    func exitDemo() { generation += 1; demo = false; mail = []; events = []; lastSync = nil; syncNote = nil }
    func showDemo() {
        generation += 1; demo = true; syncNote = nil
        let samples: [(String, String, String, String, String, Int, Bool)] = [
            ("Maya Chen", "The next chapter for Northwind", "Hi Alex,\n\nLoved our conversation yesterday. We’d like to find time this week to talk through the next round and meet the rest of the team.\n\nThe way you’re thinking about making communication feel more personal really stayed with us. There’s something special in the details you showed.\n\nWould Thursday afternoon work? We can come by the studio, or find a quiet spot nearby. I’ll bring a few thoughts on the timeline so we can make the most of the conversation.\n\nNo need to put together a deck. We’d love to see what you’re working on, just as it is.\n\nLooking forward to it,\nMaya", "Investors", "A direct follow-up about your next funding round.", 96, false),
            ("Alex Rivera", "A few thoughts on the new inbox", "The glass treatment is looking great. I put together a few notes on the mobile interactions—especially the transition from the inbox to a conversation.", "Product", "Feedback on the mobile design needs your input.", 87, true),
            ("Jordan Lee", "Agreement ready for your review", "The updated agreement is attached in the original email. Could you take a look at the timeline before Thursday?", "Contracts", "Review requested before Thursday.", 82, false),
            ("Sofia", "Dinner on Friday?", "Found a little place in the East Village that I think you’d love. Are you around at 7?", "Home", "A personal invitation waiting for an answer.", 68, false),
            ("The Creative Independent", "On making room for new ideas", "A conversation about creative routines, paying attention, and knowing when to start again.", "Newsletters", "A newsletter to read when you have a moment.", 24, false)
        ]
        mail = samples.enumerated().map { i, item in
            Mail(account: i < 3 ? "demo@work.example" : "demo@example.com", gmailID: "demo-\(i)", threadID: "demo-\(i)", sender: item.0,
                 senderAddress: "hello@example.com", subject: item.1, body: item.2, date: Date().addingTimeInterval(Double(-i * 2200)), unread: true,
                 starred: item.6, score: item.5, category: item.3, reason: item.4)
        }
        let today = Calendar.current.startOfDay(for: Date())
        events = [CalendarEvent(account: "demo@work.example", googleID: "demo-event", title: "Design catch-up", start: today.addingTimeInterval(15 * 3600), end: today.addingTimeInterval(15.5 * 3600), allDay: false, location: "Studio", link: nil),
                  CalendarEvent(account: "demo@example.com", googleID: "demo-dinner", title: "Dinner with Sofia", start: today.addingTimeInterval(86400 + 19 * 3600), end: today.addingTimeInterval(86400 + 20.5 * 3600), allDay: false, location: "East Village", link: nil)]
    }
}
