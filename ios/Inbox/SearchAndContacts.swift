import SwiftUI
import QuickLook

// MARK: - Gmail-wide thread search

struct ThreadHit: Identifiable, Equatable {
    var mail: Mail          // the thread's latest message, used to open the conversation
    var count: Int          // messages in the thread
    var id: String { mail.account + ":" + mail.threadID }
}

extension GoogleAPI {
    /// Searches all of an account's mail with Gmail's own search (the same syntax as the Gmail search box).
    func searchThreads(_ account: String, query: String, limit: Int = 15) async throws -> [ThreadHit] {
        struct Listing: Decodable { struct Item: Decodable { var id: String }; var threads: [Item]? }
        struct Thread: Decodable { var messages: [GmailMessage]? }
        let base = "https://gmail.googleapis.com/gmail/v1/users/me"
        let list = try JSONDecoder().decode(Listing.self, from: await data(account, base + "/threads", query: ["q": query, "maxResults": String(limit)]))
        var hits: [ThreadHit] = []
        for item in list.threads ?? [] {
            let thread = try JSONDecoder().decode(Thread.self, from: await data(account, base + "/threads/" + item.id, query: ["format": "metadata"]))
            guard let last = thread.messages?.last else { continue }
            var mail = last.mail(account: account)
            mail.body = last.snippet.map { $0.replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&") } ?? ""
            hits.append(ThreadHit(mail: mail, count: thread.messages?.count ?? 1))
        }
        return hits
    }

    /// People you have written to: the To and Cc of recent Sent mail.
    func sentRecipients(_ account: String, limit: Int = 150) async throws -> [String] {
        struct Listing: Decodable { struct Item: Decodable { var id: String }; var messages: [Item]? }
        let base = "https://gmail.googleapis.com/gmail/v1/users/me"
        let list = try JSONDecoder().decode(Listing.self, from: await data(account, base + "/messages", query: ["q": "in:sent", "maxResults": String(limit)]))
        var found: [String] = []
        for item in list.messages ?? [] {
            let raw = try await data(account, base + "/messages/" + item.id, query: ["format": "metadata", "metadataHeaders": "To"])
            let message = try JSONDecoder().decode(GmailMessage.self, from: raw)
            found += Contacts.split(message.payload?.header("To") ?? "")
        }
        return found
    }
}

struct SearchView: View {
    @EnvironmentObject var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ThreadHit] = []
    @State private var searching = false
    @State private var failure: String?
    @State private var opened: Mail?
    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange).listRowBackground(Color.clear) }
                if !query.isEmpty && !searching && hits.isEmpty && failure == nil {
                    Text("No conversations match.").foregroundStyle(Palette.dim).listRowBackground(Color.clear)
                }
                ForEach(hits) { hit in
                    Button { opened = hit.mail } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hit.mail.sender).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                if hit.count > 1 { Text("\(hit.count)").font(.caption2.weight(.semibold)).foregroundStyle(Palette.dim) }
                                Spacer()
                                Text(hit.mail.date, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(Palette.dim)
                            }
                            Text(hit.mail.subject).font(.subheadline).foregroundStyle(Palette.blue).lineLimit(1)
                            Text(hit.mail.body).font(.caption).foregroundStyle(Palette.dim).lineLimit(2)
                            Text(store.accounts.first { $0.id == hit.mail.account }?.name ?? hit.mail.account).font(.caption2).foregroundStyle(Palette.dim)
                        }.padding(.vertical, 4)
                    }.listRowBackground(Color.white.opacity(0.04))
                }
            }
            .scrollContentBackground(.hidden).background { GlassBackground() }
            .overlay { if searching && hits.isEmpty { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all mail")
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $opened) { mail in MessageView(initial: mail) }
            .task(id: query) { await run() }
        }
    }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { hits = []; failure = nil; return }
        // Wait for typing to pause before asking Gmail.
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        if store.demo {
            hits = store.mail.filter { ($0.sender + " " + $0.subject + " " + $0.body).localizedCaseInsensitiveContains(text) }
                .map { ThreadHit(mail: $0, count: 1) }
            return
        }
        searching = true; failure = nil
        defer { searching = false }
        var found: [ThreadHit] = [], errors: [String] = []
        for account in store.accounts {
            do { found += try await store.api.searchThreads(account.id, query: text) }
            catch is CancellationError { return }
            catch { errors.append("\(account.name): \(error.localizedDescription)") }
        }
        guard !Task.isCancelled else { return }
        hits = found.sorted { $0.mail.date > $1.mail.date }
        failure = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

extension Mail: Hashable { func hash(into hasher: inout Hasher) { hasher.combine(id) } }

// MARK: - People you've emailed, for the To, Cc and Bcc fields

struct Contact: Hashable {
    var name: String
    var address: String
    var display: String { name.isEmpty || name == address ? address : "\(name) <\(address)>" }
}

@MainActor final class Contacts: ObservableObject {
    @Published private(set) var all: [Contact] = []
    private var loaded = false

    /// Splits a header like `Ana <ana@x.com>, b@y.com` into its addresses.
    nonisolated static func split(_ header: String) -> [String] {
        header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") }
    }
    nonisolated static func parse(_ item: String) -> Contact? {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return address.contains("@") ? Contact(name: name, address: address) : nil
        }
        return trimmed.contains("@") ? Contact(name: "", address: trimmed) : nil
    }

    /// Senders from loaded mail right away; people from Sent mail once they've loaded.
    func load(store: InboxStore) async {
        merge(store.mail.map { Contact(name: $0.sender, address: $0.senderAddress) }, rank: 1)
        guard !loaded, !store.demo else { return }
        loaded = true
        for account in store.accounts {
            if let sent = try? await store.api.sentRecipients(account.id) {
                merge(sent.compactMap(Self.parse), rank: 3)
            }
        }
    }

    private var weight: [String: Int] = [:]
    private func merge(_ people: [Contact], rank: Int) {
        var byAddress = Dictionary(all.map { ($0.address.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for person in people where !person.address.isEmpty && !Self.automated(person.address) {
            let key = person.address.lowercased()
            weight[key, default: 0] += rank
            if byAddress[key] == nil || (byAddress[key]!.name.isEmpty && !person.name.isEmpty) { byAddress[key] = person }
        }
        all = byAddress.values.sorted { weight[$0.address.lowercased(), default: 0] > weight[$1.address.lowercased(), default: 0] }
    }
    nonisolated static func automated(_ address: String) -> Bool {
        address.range(of: #"no-?reply|notifications?@|mailer|donotreply|bounce"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The best matches for what's being typed after the last comma, most-written-to first.
    func matches(_ text: String, limit: Int = 5) -> [Contact] {
        let term = (text.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard term.count >= 1 else { return [] }
        let already = Set(Self.split(text).compactMap { Self.parse($0)?.address.lowercased() })
        return all.filter { !already.contains($0.address.lowercased()) && ($0.name.lowercased().contains(term) || $0.address.lowercased().contains(term)) }
            .prefix(limit).map { $0 }
    }
    /// Replaces the half-typed last entry with the chosen person.
    static func complete(_ text: String, with person: Contact) -> String {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = person.display
        return parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }
}

/// A To, Cc or Bcc field that suggests people as you type.
struct RecipientField: View {
    let label: String
    @Binding var text: String
    @ObservedObject var contacts: Contacts
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(label, text: $text).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused)
            if focused {
                ForEach(contacts.matches(text), id: \.self) { person in
                    Button { text = Contacts.complete(text, with: person) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name.isEmpty ? person.address : person.name).font(.subheadline.weight(.medium))
                            if !person.name.isEmpty { Text(person.address).font(.caption).foregroundStyle(Palette.dim) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Attachments: tap to open in Quick Look (PDFs, images, documents), with Share from there.

extension GoogleAPI {
    func attachment(_ account: String, messageID: String, attachmentID: String) async throws -> Data {
        struct Body: Decodable { var data: String }
        let raw = try await data(account, "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageID)/attachments/\(attachmentID)")
        let body = try JSONDecoder().decode(Body.self, from: raw)
        guard let bytes = Data(base64URL: body.data) else { throw URLError(.cannotDecodeContentData) }
        return bytes
    }
}

struct AttachmentButton: View {
    @EnvironmentObject var store: InboxStore
    let account: String
    let messageID: String
    let part: GmailMessage.Part
    @State private var loading = false
    @State private var opened: URL?
    @State private var failure: String?

    private var name: String { (part.filename?.isEmpty == false ? part.filename! : "Attachment") }
    private var size: String {
        let bytes = part.body?.size ?? 0
        return bytes > 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(max(1, bytes / 1000)) KB"
    }
    private var icon: String {
        let type = part.mimeType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("spreadsheet") || type.contains("excel") || name.hasSuffix(".csv") { return "tablecells" }
        if type.contains("presentation") || type.contains("powerpoint") { return "rectangle.on.rectangle" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }

    var body: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(failure ?? size).font(.system(size: 11)).foregroundStyle(failure == nil ? Palette.dim : .orange)
                }
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.forward.app").foregroundStyle(Palette.dim) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(loading || store.demo)
        .quickLookPreview($opened)
        .accessibilityLabel("Open \(name)")
    }

    private func open() async {
        loading = true; failure = nil
        defer { loading = false }
        do {
            let bytes: Data
            if let inline = part.body?.data, let decoded = Data(base64URL: inline) { bytes = decoded }
            else if let id = part.body?.attachmentId { bytes = try await store.api.attachment(account, messageID: messageID, attachmentID: id) }
            else { throw URLError(.fileDoesNotExist) }
            // Each attachment gets its own folder so two files with the same name never collide.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Attachments/\(messageID)-\(abs(name.hashValue))", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            opened = url
        } catch { failure = "Couldn't open it. Try again." }
    }
}
