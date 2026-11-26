import SwiftUI

// Selection survives refreshes; removing the current message advances to its successor.
enum InboxSelection {
    static func reconcile(selected: String?, old: [String], new: [String]) -> String? {
        guard !new.isEmpty else { return nil }
        if let selected, new.contains(selected) { return selected }
        let index = selected.flatMap { old.firstIndex(of: $0) } ?? 0
        return new[min(index, new.count - 1)]
    }
    static func matches(_ mail: Mail, filter: String, account: String, search: String) -> Bool {
        (account == "all" || mail.account == account) &&
        (filter == "All mail" || (filter == "Unread" && mail.unread) ||
         (filter == "Read" && !mail.unread) || (filter == "Starred" && mail.starred) || mail.category == filter) &&
        (search.isEmpty || (mail.sender + " " + mail.subject + " " + mail.body).localizedCaseInsensitiveContains(search))
    }
}

struct SplitInboxView: View {
    @EnvironmentObject var store: InboxStore
    @State private var filter = "Unread"
    @State private var account = "all"
    @State private var search = ""
    @State private var selectedID: String?
    @State private var expanded = false
    @State private var drag: CGFloat = 0
    @State private var menu = false
    @State private var presented: InboxPresentation?
    @State private var lastRead: Mail?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 100
    var filtered: [Mail] {
        store.mail.filter { InboxSelection.matches($0, filter: filter, account: account, search: search) }
            .sorted { $0.score == $1.score ? $0.date > $1.date : $0.score > $1.score }
    }
    var selected: Mail? { filtered.first { $0.id == selectedID } ?? filtered.first }
    var accountName: String { store.accounts.first { $0.id == account }?.name ?? "All inboxes" }

    var body: some View {
        GeometryReader { geometry in
            let readerHeight = max(260, geometry.size.height * 0.53)
            let inboxHeight = geometry.size.height - readerHeight
            ZStack(alignment: .bottom) {
                GlassBackground()
                VStack(spacing: 0) {
                    header
                    ticker(height: max(80, inboxHeight - 64))
                    Spacer(minLength: 0)
                }
                .accessibilityHidden(expanded || menu)
                .allowsHitTesting(!expanded && !menu)

                if let mail = selected {
                    let full = geometry.size.height + geometry.safeAreaInsets.bottom
                    let resting = readerHeight + geometry.safeAreaInsets.bottom
                    ReaderPanel(mail: mail, expanded: $expanded, drag: $drag, travel: full - resting,
                                markRead: { Task { await markRead(mail) } },
                                reply: { presented = .reply(mail) })
                        .frame(height: min(full, max(resting * 0.7, (expanded ? full : resting) - drag)))
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                        .accessibilityHidden(menu)
                } else {
                    emptyReader.frame(height: readerHeight + geometry.safeAreaInsets.bottom)
                }

                if menu {
                    Color.black.opacity(0.34).ignoresSafeArea().onTapGesture { withAnimation(.snappy) { menu = false } }
                    drawer.frame(width: min(340, geometry.size.width - 40))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .animation(.interactiveSpring(response: 0.36, dampingFraction: 0.86), value: expanded)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: drag)
            .animation(.snappy(duration: 0.25), value: menu)
            .onAppear { selectedID = filtered.first?.id }
            .onChange(of: filtered.map(\.id)) { old, new in
                selectedID = InboxSelection.reconcile(selected: selectedID, old: old, new: new)
                if new.isEmpty { expanded = false }
            }
            .sheet(item: $presented) { destination in
                switch destination {
                case .compose: ComposeView(reply: nil)
                case .reply(let mail): ComposeView(reply: mail)
                case .preview(let mail):
                    MailPreview(mail: mail) {
                        selectedID = mail.id; presented = nil
                    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                case .calendar: DismissibleDestination { AgendaView() }
                case .accounts: DismissibleDestination { SettingsView() }
                case .search: SearchView()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Button { withAnimation { menu = true } } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 19, weight: .medium)).frame(width: 42, height: 42).inboxGlass()
                }.accessibilityLabel("Open inbox menu").accessibilityIdentifier("inboxMenu")
                Spacer()
                Text(filter == "Unread" ? "Inbox" : filter).font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.7)
                Spacer()
                Button { presented = .search } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).frame(width: 42, height: 42).inboxGlass()
                }.accessibilityLabel("Search all mail")
                Button { presented = .compose } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .medium)).frame(width: 42, height: 42).inboxGlass()
                }.accessibilityLabel("Compose email")
            }
        }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 10)
            .overlay(alignment: .bottom) { if store.refreshing { ProgressView().controlSize(.mini).offset(y: 4) } }
    }

    private func ticker(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { mail in
                        TickerRow(mail: mail, selected: selected?.id == mail.id,
                                  pending: store.pending.contains(mail.id), height: rowHeight,
                                  tap: { withAnimation(.snappy) { selectedID = mail.id; proxy.scrollTo(mail.id, anchor: .top) } },
                                  preview: { presented = .preview(mail) },
                                  markRead: { Task { await markRead(mail) } })
                            .id(mail.id)
                    }
                }.scrollTargetLayout()
                // Allow the last message to occupy the first slot too.
                Color.clear.frame(height: max(0, height - rowHeight)).accessibilityHidden(true)
            }
            .scrollPosition(id: $selectedID, anchor: .top)
            .scrollTargetBehavior(.viewAligned)
            .frame(height: height)
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .refreshable { await store.refresh() }
            .accessibilityIdentifier("inboxTicker")
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Palette.background.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22).allowsHitTesting(false)
            }
        }
    }

    private var emptyReader: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.blue)
            Text(search.isEmpty ? "A little breathing room." : "No matching messages").font(.title3.weight(.medium))
            Text(filter == "Unread" ? "Your read messages are in the menu." : "Choose another section in the menu.").font(.subheadline).foregroundStyle(Palette.dim)
            if let lastRead {
                Button("Undo mark as read") { Task { await store.flag(lastRead, label: "UNREAD", value: true); self.lastRead = nil } }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(readerSurface)
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your inbox").font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.8)
                Spacer()
                Button { menu = false } label: { Image(systemName: "xmark").frame(width: 36, height: 36).inboxGlass() }.accessibilityLabel("Close menu")
            }.padding(.bottom, 24)
            Button { menu = false; presented = .search } label: { HStack { Image(systemName: "magnifyingglass"); Text("Search all mail").foregroundStyle(Palette.dim); Spacer() } }
                .accessibilityIdentifier("menuSearch")
                .font(.subheadline).padding(13).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15)).padding(.bottom, 24)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach([("Unread", "tray"), ("Read", "checkmark.circle"), ("Starred", "star"), ("All mail", "tray.full")], id: \.0) { title, icon in
                        drawerFilter(title, icon: icon)
                    }
                    sectionLabel("ACCOUNTS")
                    accountButton("All inboxes", id: "all")
                    ForEach(store.accounts) { account in accountButton(account.name, id: account.id) }
                    sectionLabel("CATEGORIES")
                    ForEach(Array(Set(store.mail.map(\.category))).sorted(), id: \.self) { category in drawerFilter(category, icon: "circle.fill") }
                    sectionLabel("MORE")
                    Button { menu = false; presented = .calendar } label: { Label("Calendar", systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading).padding(13) }
                    Button { menu = false; presented = .accounts } label: { Label("Accounts & sync", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).padding(13) }
                    Button { menu = false; Task { await store.refresh() } } label: { Label("Check for new mail", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading).padding(13) }
                    if let note = store.syncNote { Text(note).font(.caption).foregroundStyle(Palette.dim).padding(13) }
                }
            }
            Text("A little less noise.").font(.caption).foregroundStyle(Palette.dim).padding(.top, 16)
        }.padding(22).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 30).fill(.ultraThinMaterial).overlay(.blue.opacity(0.06)).ignoresSafeArea(edges: .bottom) }
            .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.1)).frame(width: 0.5) }
            .accessibilityAddTraits(.isModal)
    }
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(Palette.dim).padding(.top, 23).padding(.bottom, 7).padding(.leading, 13)
    }
    private func drawerFilter(_ title: String, icon: String) -> some View {
        Button {
            filter = title; selectedID = filtered.first?.id; expanded = false; menu = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: title == "Unread" || title == "Read" || title == "Starred" || title == "All mail" ? 17 : 8)).frame(width: 20).foregroundStyle(Palette.category(title))
                Text(title)
                Spacer()
                Text("\(store.mail.filter { InboxSelection.matches($0, filter: title, account: account, search: search) }.count)").font(.caption).foregroundStyle(Palette.dim)
            }.padding(13).background(filter == title ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 14))
        }.foregroundStyle(.white).accessibilityIdentifier("filter-\(title)")
    }
    private func accountButton(_ title: String, id: String) -> some View {
        Button { account = id; selectedID = filtered.first?.id; menu = false } label: {
            HStack { Text(title); Spacer(); if account == id { Image(systemName: "checkmark").font(.caption).foregroundStyle(Palette.blue) } }.padding(.horizontal, 13).padding(.vertical, 10)
        }.foregroundStyle(Palette.dim)
    }
    private func markRead(_ mail: Mail) async {
        guard mail.unread else { return }
        await store.flag(mail, label: "UNREAD", value: false)
        if store.mail.first(where: { $0.id == mail.id })?.unread == false { lastRead = mail }
    }
}

private enum InboxPresentation: Identifiable {
    case compose, reply(Mail), preview(Mail), calendar, accounts, search
    var id: String {
        switch self {
        case .compose: return "compose"
        case .reply(let mail): return "reply:" + mail.id
        case .preview(let mail): return "preview:" + mail.id
        case .calendar: return "calendar"
        case .accounts: return "accounts"
        case .search: return "search"
        }
    }
}

struct TickerRow: View {
    let mail: Mail
    let selected: Bool
    let pending: Bool
    let height: CGFloat
    let tap: () -> Void
    let preview: () -> Void
    let markRead: () -> Void
    @State private var swipe: CGFloat = 0
    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 18).fill(Palette.blue.opacity(swipe < -10 ? 0.22 : 0))
            Label("Read", systemImage: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.blue).padding(.trailing, 24).opacity(min(1, -swipe / 70))
            HStack(alignment: .center, spacing: 12) {
                Capsule().fill(selected ? Palette.blue : .clear).frame(width: 3, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(mail.sender).font(.system(size: 15, weight: selected ? .semibold : .medium)).lineLimit(1)
                        if mail.starred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                        Spacer(minLength: 4)
                        Text(mail.date, style: .time).font(.system(size: 10)).foregroundStyle(Palette.dim)
                    }
                    Text(mail.subject).font(.system(size: 14)).foregroundStyle(selected ? Palette.blue : .white.opacity(0.75)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(Palette.category(mail.category)).frame(width: 4, height: 4)
                        Text(mail.category).foregroundStyle(Palette.category(mail.category))
                        Text("·").foregroundStyle(Palette.dim)
                        Text(mail.body).foregroundStyle(Palette.dim).lineLimit(1)
                    }.font(.system(size: 10))
                }
                if pending { ProgressView().controlSize(.small) }
            }
            .padding(.leading, 10).padding(.trailing, 16).frame(height: height - 6)
            .background {
                RoundedRectangle(cornerRadius: 18).fill(selected ? .white.opacity(0.08) : .white.opacity(0.015))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Palette.blue.opacity(0.2) : .clear, lineWidth: 0.6) }
            }.offset(x: swipe)
        }
        .frame(height: height).contentShape(Rectangle())
        .overlay {
            RowGestureSurface(tap: tap, preview: preview, moved: { distance in
                if mail.unread { swipe = min(0, max(-140, distance)) }
            }, finished: { distance in
                if mail.unread && distance < -65 { markRead() }
                withAnimation(.snappy) { swipe = 0 }
            })
        }
        .disabled(pending)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mail.sender), \(mail.subject)")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Select", tap)
        .accessibilityAction(named: "Preview", preview)
        .accessibilityAction(named: "Mark read", markRead)
        .accessibilityIdentifier("mail-\(mail.gmailID)")
    }
}

/// Rounded only on top: the panel runs off the bottom of the screen.
private var readerSurface: some View {
    UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
        .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.27, blue: 0.43), Color(red: 0.095, green: 0.15, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay { UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.7) }
        .shadow(color: .black.opacity(0.2), radius: 22, y: -5)
}

struct ReaderPanel: View {
    @EnvironmentObject var store: InboxStore
    let mail: Mail
    @Binding var expanded: Bool
    @Binding var drag: CGFloat
    let travel: CGFloat
    let markRead: () -> Void
    let reply: () -> Void
    @State private var atTop = true

    /// Follows the finger; on release, the throw (velocity) decides whether it opens or closes.
    private var follow: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width) else { return }
                // Collapsed: drag up opens. Expanded: only pull down, and only from the top of the email.
                if !expanded { drag = dy } else if atTop && dy > 0 { drag = dy }
            }
            .onEnded { value in
                let thrown = value.predictedEndTranslation.height
                if !expanded && (thrown < -travel * 0.35 || drag < -travel * 0.5) { expanded = true }
                else if expanded && drag > 0 && (thrown > travel * 0.3 || drag > travel * 0.4) { expanded = false }
                drag = 0
            }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Capsule().fill(.white.opacity(0.28)).frame(width: 36, height: 5).padding(.top, 9).padding(.bottom, 6)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                    .accessibilityLabel(expanded ? "Collapse reader" : "Expand reader").accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("readerExpand")
                    .onTapGesture { expanded.toggle() }
                ScrollView {
                    MessageContent(mail: mail, compact: !expanded)
                        .padding(.horizontal, 22).padding(.top, 8)
                        .padding(.bottom, 110) // room to scroll the end of the email above the floating buttons
                        .background(GeometryReader { g in Color.clear.preference(key: ReaderScrollTop.self, value: g.frame(in: .named("reader")).minY) })
                }
                .coordinateSpace(name: "reader")
                .onPreferenceChange(ReaderScrollTop.self) { atTop = $0 >= -1 }
                .scrollDisabled(!expanded)
                .accessibilityIdentifier("readerContent")
            }
            .simultaneousGesture(follow)
            // The buttons float over the email; it scrolls underneath them.
            ReaderActions(mail: mail, markRead: markRead, reply: reply)
                .padding(.top, 18).padding(.bottom, 8)
                .background(LinearGradient(colors: [.clear, Palette.background.opacity(0.72)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
                .safeAreaPadding(.bottom)
        }
        .background(readerSurface)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous))
        .accessibilityValue(expanded ? "Expanded" : "Split")
        .accessibilityAction(named: expanded ? "Collapse" : "Expand") { expanded.toggle() }
        .accessibilityAction(.escape) { expanded = false }
    }
}

private struct ReaderScrollTop: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessageContent: View {
    @EnvironmentObject var store: InboxStore
    let mail: Mail
    var compact = false
    @State private var messages: [GmailMessage] = []
    @State private var loadedID: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var inlineHTML: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 15 : 24) {
            Text(mail.subject).font(.system(size: compact ? 26 : 32, weight: .semibold, design: .rounded)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("readerSubject")
            sender(mail)
            if messages.isEmpty || loadedID != mail.id {
                Text(mail.body).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(messages, id: \.id) { message in
                    let content = message.mail(account: mail.account)
                    VStack(alignment: .leading, spacing: 14) {
                        if messages.count > 1 { sender(content) }
                        if let html = message.payload?.html { HTMLBody(html: inlineHTML[message.id] ?? html) }
                        else { Text(content.body).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled) }
                        ForEach(Array((message.payload?.attachments ?? []).enumerated()), id: \.offset) { _, part in
                            AttachmentButton(account: mail.account, messageID: message.id, part: part)
                        }
                    }
                }
            }
            if loading { ProgressView().controlSize(.mini) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(Palette.blue)
                Text(mail.reason).foregroundStyle(Palette.dim)
            }.font(.system(size: 12)).lineSpacing(4).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: mail.id) {
                messages = []; loadedID = nil; failure = nil; loading = false
                guard !store.demo else { return }
                // Debounce ticker scrolling so passing cells don't start network requests.
                do {
                    try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation()
                    loading = true
                    let result = try await store.api.thread(mail)
                    try Task.checkCancellation()
                    messages = result; loadedID = mail.id; loading = false
                    inlineHTML = [:]
                    for message in result { await fillInlineImages(message) }
                } catch is CancellationError { }
                catch { if !Task.isCancelled { failure = error.localizedDescription; loading = false } }
            }
    }
    /// Embedded images that didn't come with the message are fetched once and dropped into the HTML.
    private func fillInlineImages(_ message: GmailMessage) async {
        guard var html = message.payload?.html, let parts = message.payload?.inlineImages else { return }
        var changed = false
        for part in parts where part.body?.data == nil {
            let cid = part.header("Content-ID").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard !cid.isEmpty, html.contains("cid:" + cid), let id = part.body?.attachmentId,
                  let bytes = try? await store.api.attachment(mail.account, messageID: message.id, attachmentID: id) else { continue }
            html = html.replacingOccurrences(of: "cid:" + cid, with: "data:\(part.mimeType ?? "image/png");base64," + bytes.base64EncodedString())
            changed = true
        }
        if changed { inlineHTML[message.id] = html }
    }
    private func sender(_ item: Mail) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.category(item.category).opacity(0.18)).frame(width: 33, height: 33)
                .overlay(Text(item.sender.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.category(item.category)))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.sender).font(.system(size: 13, weight: .semibold))
                Text("to \(item.account.hasSuffix("@work.example") ? "Work" : "Personal") · \(item.date.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
            Spacer()
        }
    }
}

struct ReaderActions: View {
    @EnvironmentObject var store: InboxStore
    let mail: Mail
    let markRead: () -> Void
    let reply: () -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    if mail.unread { markRead() }
                    else { Task { await store.flag(mail, label: "UNREAD", value: true) } }
                } label: { action(mail.unread ? "Read" : "Unread", icon: mail.unread ? "checkmark" : "envelope.badge", prominent: true) }.accessibilityIdentifier("readerRead")
                Button { Task { await store.flag(mail, label: "STARRED", value: !mail.starred) } } label: { action(mail.starred ? "Starred" : "Star", icon: mail.starred ? "star.fill" : "star") }.accessibilityIdentifier("readerStar")
                Button(action: reply) { action("Reply", icon: "arrowshape.turn.up.left") }.accessibilityIdentifier("readerReply")
                Button { Task { _ = await store.trash(mail) } } label: { action("Trash", icon: "trash") }
                if !store.demo, let url = URL(string: "https://mail.google.com/mail/u/?authuser=\(mail.account.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")#all/\(mail.threadID)") {
                    Link(destination: url) { action("Original", icon: "arrow.up.right.square") }
                }
            }.padding(.horizontal, 20).padding(.vertical, 5)
        }.scrollClipDisabled().disabled(store.pending.contains(mail.id))
            .accessibilityIdentifier("readerActions")
    }
    private func action(_ title: String, icon: String, prominent: Bool = false) -> some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .medium)).padding(.horizontal, 17).frame(height: 47)
            .foregroundStyle(prominent ? Color.white : Palette.blue).inboxGlass(tinted: prominent)
    }
}

struct MailPreview: View {
    @Environment(\.dismiss) private var dismiss
    let mail: Mail
    let select: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Preview").font(.subheadline.weight(.semibold)); Spacer(); Text("Stays unread").font(.caption).foregroundStyle(Palette.dim); Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 36).inboxGlass() }.accessibilityLabel("Close preview") }.padding(22)
            ScrollView { MessageContent(mail: mail).padding(.horizontal, 24).padding(.bottom, 24) }
            Button(action: select) { Label("Read in split view", systemImage: "rectangle.split.1x2").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(17).inboxGlass() }.padding(20).accessibilityIdentifier("previewSelect")
        }.background { GlassBackground() }
    }
}

private struct DismissibleDestination<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { HStack { Spacer(); Button("Done") { dismiss() } }.padding(.horizontal, 24).padding(.top, 18); content() }.background { GlassBackground() }
    }
}

extension View {
    @ViewBuilder func inboxGlass(tinted: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tinted ? Palette.blue.opacity(0.3) : .clear).interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule()).overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.7) }
        }
    }
}
