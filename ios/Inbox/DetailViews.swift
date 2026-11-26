import SwiftUI

struct MessageView: View {
    @EnvironmentObject var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    let initial: Mail
    @State private var messages: [GmailMessage] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var replying = false
    var mail: Mail { store.mail.first { $0.id == initial.id } ?? initial }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(mail.category.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Palette.category(mail.category))
                Text(mail.subject).font(.system(size: 30, weight: .semibold)).tracking(-0.6)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkle").foregroundStyle(Palette.blue)
                    Text(mail.reason).font(.subheadline).foregroundStyle(Palette.dim).lineSpacing(4)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                if loading { ProgressView("Loading conversation…").frame(maxWidth: .infinity) }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange); Button("Try again") { Task { await load() } } }
                if messages.isEmpty { messageBody(mail) }
                ForEach(messages, id: \.id) { message in
                    if let html = message.payload?.html {
                        messageHeader(message.mail(account: mail.account))
                        HTMLBody(html: html)
                    } else {
                        messageBody(message.mail(account: mail.account))
                    }
                    if !(message.payload?.attachments.isEmpty ?? true) {
                        ForEach(Array((message.payload?.attachments ?? []).enumerated()), id: \.offset) { _, part in
                            AttachmentButton(account: mail.account, messageID: message.id, part: part)
                        }
                    }
                    Divider().overlay(.white.opacity(0.08))
                }
                Button { replying = true } label: { Label("Reply", systemImage: "arrowshape.turn.up.left").frame(maxWidth: .infinity).padding(16).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18)) }
            }.padding(24)
        }.background { GlassBackground() }.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await store.flag(mail, label: "STARRED", value: !mail.starred) } } label: { Image(systemName: mail.starred ? "star.fill" : "star") }.accessibilityLabel(mail.starred ? "Unstar" : "Star")
                    Menu {
                        Button(mail.unread ? "Mark read" : "Mark unread", systemImage: "envelope") { Task { await store.flag(mail, label: "UNREAD", value: !mail.unread) } }
                        if !store.demo, let url = URL(string: "https://mail.google.com/mail/u/?authuser=\(mail.account.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")#all/\(mail.threadID)") { Link("Open in Gmail", destination: url) }
                        Button("Move to Trash", systemImage: "trash", role: .destructive) { Task { if await store.trash(mail) { dismiss() } } }
                    } label: { Image(systemName: "ellipsis") }
                }
            }.disabled(store.pending.contains(mail.id))
            .sheet(isPresented: $replying) { ComposeView(reply: mail) }
            .task { await load() }
    }
    func messageHeader(_ message: Mail) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) { Text(message.sender).fontWeight(.semibold); Text(message.senderAddress).font(.caption).foregroundStyle(Palette.dim) }
            Spacer()
            Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2).foregroundStyle(Palette.dim)
        }
    }
    func messageBody(_ message: Mail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) { Text(message.sender).fontWeight(.semibold); Text(message.senderAddress).font(.caption).foregroundStyle(Palette.dim) }
                Spacer()
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2).foregroundStyle(Palette.dim)
            }
            Text(message.body).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func load() async {
        guard !store.demo else { return }
        loading = true; loadError = nil
        defer { loading = false }
        do { messages = try await store.api.thread(mail) } catch { loadError = error.localizedDescription }
    }
}

struct ComposeView: View {
    enum Mode: String, CaseIterable { case reply = "Reply", replyAll = "Reply all", forward = "Forward" }
    @EnvironmentObject var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    let reply: Mail?
    @State var mode: Mode = .reply
    @State private var account = ""
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showCopies = false
    @State private var subject = ""
    @State private var text = ""
    @State private var original: GmailMessage.Part?
    @State private var sending = false
    @State private var failure: String?
    @State private var discard = false
    @State private var demoSent = false
    @StateObject private var contacts = Contacts()
    private var addresses: (String) -> [String] = { $0.split(whereSeparator: { ",;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var valid: Bool {
        let all = addresses(to) + addresses(cc) + addresses(bcc)
        return !all.isEmpty && all.allSatisfy { $0.contains("@") }
    }
    init(reply: Mail?, mode: Mode = .reply) { self.reply = reply; _mode = State(initialValue: mode) }
    var body: some View {
        NavigationStack {
            Form {
                if store.demo { Text("Demo mode · nothing will be sent").foregroundStyle(Palette.blue) }
                if reply != nil {
                    Picker("Respond", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).listRowBackground(Color.clear)
                }
                Section {
                    Picker("From", selection: $account) { ForEach(store.accounts) { Text($0.id).tag($0.id) } }.disabled(reply != nil)
                    RecipientField(label: "To", text: $to, contacts: contacts)
                    if showCopies || !cc.isEmpty || !bcc.isEmpty {
                        RecipientField(label: "Cc", text: $cc, contacts: contacts)
                        RecipientField(label: "Bcc", text: $bcc, contacts: contacts)
                    } else {
                        Button("Add Cc or Bcc") { showCopies = true }.font(.subheadline)
                    }
                    TextField("Subject", text: $subject)
                }
                Section { TextEditor(text: $text).frame(minHeight: 260).accessibilityLabel("Message body") }
                if mode == .forward && !(original?.attachments.isEmpty ?? true) {
                    Section { Text("Attachments aren't forwarded yet. Open Gmail to forward them.").font(.caption).foregroundStyle(Palette.dim) }
                }
                if let failure { Section { Text(failure).foregroundStyle(.orange); Text("Your draft is still here. Check Sent mail before retrying if the connection failed during sending.").font(.caption) } }
            }.scrollContentBackground(.hidden).background { GlassBackground() }
                .navigationTitle(reply == nil ? "New message" : mode.rawValue).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if !text.isEmpty || (reply == nil && (!to.isEmpty || !subject.isEmpty)) { discard = true } else { dismiss() } }.disabled(sending) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await send() } } label: { if sending { ProgressView() } else { Text("Send").fontWeight(.semibold) } }
                            .disabled(sending || account.isEmpty || !valid || (mode != .forward && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
        }.interactiveDismissDisabled(sending || !text.isEmpty || !to.isEmpty || !subject.isEmpty)
            .confirmationDialog("Discard this draft?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
            .alert("Demo message", isPresented: $demoSent) { Button("Done") { dismiss() } } message: { Text("Nothing was sent. Connect Google to send real email.") }
            .onAppear { account = reply?.account ?? store.accounts.first?.id ?? ""; fill() }
            .onChange(of: mode) { fill() }
            .task { await contacts.load(store: store) }
            .task {
                guard let reply, !store.demo else { return }
                original = try? await store.api.message(reply.account, id: reply.gmailID).payload
                fill()
            }
    }
    private func field(_ label: String, _ value: Binding<String>) -> some View {
        TextField(label, text: value).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    /// Prefills the recipients, subject and (for a forward) the original message for the chosen way of responding.
    private func fill() {
        guard let reply else { return }
        let head = { (name: String) in original?.header(name) ?? "" }
        let subjectLine = head("Subject").nilIfEmpty ?? reply.subject
        let mine = Set(store.accounts.map { $0.id.lowercased() } + [reply.account.lowercased()])
        let notMine = { (list: String) in addresses(list).filter { item in !mine.contains(where: { item.lowercased().contains($0) }) } }
        let sender = head("Reply-To").nilIfEmpty ?? head("From").nilIfEmpty ?? reply.senderAddress
        switch mode {
        case .reply:
            to = sender; cc = ""
            subject = subjectLine.lowercased().hasPrefix("re:") ? subjectLine : "Re: " + subjectLine
        case .replyAll:
            to = sender
            cc = (notMine(head("To")) + notMine(head("Cc"))).filter { !sender.lowercased().contains($0.lowercased()) }.joined(separator: ", ")
            showCopies = showCopies || !cc.isEmpty
            subject = subjectLine.lowercased().hasPrefix("re:") ? subjectLine : "Re: " + subjectLine
        case .forward:
            to = ""; cc = ""
            subject = subjectLine.lowercased().hasPrefix("fwd:") ? subjectLine : "Fwd: " + subjectLine
            if !text.contains("---------- Forwarded message ---------") {
                text += "\n\n---------- Forwarded message ---------\nFrom: \(head("From").nilIfEmpty ?? reply.sender)\nDate: \(head("Date"))\nSubject: \(subjectLine)\nTo: \(head("To"))\n\n\(original?.plainText ?? reply.body)"
            }
        }
    }
    func send() async {
        if store.demo { demoSent = true; return }
        sending = true; failure = nil
        defer { sending = false }
        do {
            try await store.api.send(account: account, to: addresses(to).joined(separator: ", "), cc: addresses(cc).joined(separator: ", "),
                                     bcc: addresses(bcc).joined(separator: ", "), subject: subject, body: text, reply: mode == .forward ? nil : reply)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

struct AgendaView: View {
    @EnvironmentObject var store: InboxStore
    @State private var creating = false
    @State private var account = "all"
    var events: [CalendarEvent] { store.events.filter { account == "all" || $0.account == account }.sorted { $0.start < $1.start } }
    var days: [Date] { Array(Set(events.map { Calendar.current.startOfDay(for: $0.start) })).sorted() }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Account", selection: $account) { Text("All accounts").tag("all"); ForEach(store.accounts) { Text($0.name).tag($0.id) } }
                    Text("Your next two weeks").font(.subheadline).foregroundStyle(Palette.dim)
                }.listRowBackground(Color.clear)
                if events.isEmpty { ContentUnavailableView("Room in your calendar", systemImage: "calendar", description: Text("Pull down to refresh your Google calendars.")).listRowBackground(Color.clear) }
                ForEach(days, id: \.self) { day in
                    Section {
                        ForEach(events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { event in
                            HStack(alignment: .top, spacing: 16) {
                                RoundedRectangle(cornerRadius: 2).fill(event.account.hasSuffix("@work.example") ? Palette.blue : .mint).frame(width: 3)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(event.title).font(.headline)
                                    Text(event.timeLabel).font(.subheadline).foregroundStyle(Palette.blue)
                                    if !event.location.isEmpty { Label(event.location, systemImage: "mappin").font(.caption).foregroundStyle(Palette.dim) }
                                    Text(event.account).font(.caption2).foregroundStyle(Palette.dim)
                                    if let link = event.link, link.scheme == "https" { Link(destination: link) { Label("Join Google Meet", systemImage: "video").font(.subheadline.weight(.medium)) }.padding(.top, 4) }
                                }
                            }.padding(.vertical, 12).listRowBackground(Color.white.opacity(0.04))
                        }
                    } header: { Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day()).foregroundStyle(Palette.dim) }
                }
            }.scrollContentBackground(.hidden).background { GlassBackground() }.refreshable { await store.refresh() }
                .navigationTitle("Calendar").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New event") } }
                .sheet(isPresented: $creating) { EventEditor() }
        }
    }
}

struct EventEditor: View {
    @EnvironmentObject var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var location = ""
    @State private var account = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var end = Date().addingTimeInterval(7200)
    @State private var saving = false
    @State private var failure: String?
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                if store.demo { Text("Demo calendar · changes stay in this session").font(.caption) }
                TextField("Event title", text: $title)
                Picker("Calendar", selection: $account) { ForEach(store.accounts) { Text($0.id).tag($0.id) } }
                DatePicker("Starts", selection: $start); DatePicker("Ends", selection: $end, in: start...)
                TextField("Location", text: $location)
                if let failure { Text(failure).foregroundStyle(.orange) }
            }.scrollContentBackground(.hidden).background { GlassBackground() }.navigationTitle("New event").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if title.isEmpty && location.isEmpty { dismiss() } else { discard = true } }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || account.isEmpty || end <= start) }
                }
        }.interactiveDismissDisabled(saving || !title.isEmpty || !location.isEmpty)
            .confirmationDialog("Discard this event?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
            .onAppear { account = store.accounts.first?.id ?? "" }
    }
    func save() async {
        saving = true; defer { saving = false }
        do {
            if store.demo { store.events.append(CalendarEvent(account: account, googleID: UUID().uuidString, title: title, start: start, end: end, allDay: false, location: location, link: nil)) }
            else { try await store.api.createEvent(account: account, title: title, start: start, end: end, location: location); await store.refresh() }
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

struct SettingsView: View {
    @EnvironmentObject var session: GoogleSession
    @EnvironmentObject var store: InboxStore
    @State private var signingIn = false
    var body: some View {
        NavigationStack {
            List {
                Section("Connected accounts") {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.name).font(.headline); Text(account.id).font(.subheadline).foregroundStyle(Palette.dim)
                            if !store.demo { Button("Remove from this iPhone", role: .destructive) { store.disconnect(account) }.font(.caption).padding(.top, 4) }
                        }.padding(.vertical, 8)
                    }
                    if !store.demo {
                        Button {
                            signingIn = true
                            Task { defer { signingIn = false }; do { try await session.signIn() } catch { store.error = error.localizedDescription } }
                        } label: { Label(signingIn ? "Connecting…" : "Connect Google account", systemImage: "plus") }.disabled(signingIn)
                    }
                }.listRowBackground(Color.white.opacity(0.05))
                Section("Sync") {
                    Label(store.demo ? "Sample data" : "Connected directly to Google", systemImage: "arrow.triangle.2.circlepath")
                    Text("Mail and calendar refresh when you open the app, pull to refresh, and every minute while it is active. Read status, stars, replies, and Trash are saved to the same Google accounts as your Mac.").font(.subheadline).foregroundStyle(Palette.dim)
                    Text("AI rankings are published by the Mac to Google Drive’s hidden app-data folder. New mail uses Gmail labels until the next ranking sync.").font(.subheadline).foregroundStyle(Palette.dim)
                    if let date = store.lastSync { Text("Last refreshed \(date.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    if let note = store.syncNote { Text(note).font(.caption).foregroundStyle(.orange) }
                }.listRowBackground(Color.white.opacity(0.05))
                if store.demo { Section { Button("Leave demo") { store.exitDemo(); Task { await store.refresh() } } }.listRowBackground(Color.white.opacity(0.05)) }
            }.scrollContentBackground(.hidden).background { GlassBackground() }.navigationTitle("Accounts")
        }
    }
}
