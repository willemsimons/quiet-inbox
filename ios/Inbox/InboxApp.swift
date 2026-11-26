import SwiftUI

@main struct InboxApp: App {
    @StateObject private var session: GoogleSession
    @StateObject private var store: InboxStore
    init() {
        let session = GoogleSession()
        let store = InboxStore(session: session)
        if ProcessInfo.processInfo.arguments.contains("--demo") { store.showDemo() }
        _session = StateObject(wrappedValue: session); _store = StateObject(wrappedValue: store)
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(session).environmentObject(store)
                .preferredColorScheme(.dark).tint(Palette.blue)
                .onOpenURL { session.handle($0) }
        }
    }
}

enum Palette {
    static let blue = Color(red: 0.48, green: 0.81, blue: 1)
    static let dim = Color(red: 0.62, green: 0.70, blue: 0.84)
    static let background = Color(red: 0.07, green: 0.12, blue: 0.23)
    static func category(_ value: String) -> Color {
        switch value {
        case "Investors": return Color(red: 0.8, green: 0.7, blue: 1)
        case "Contracts", "Money": return Color(red: 1, green: 0.74, blue: 0.48)
        case "Home", "Travel": return Color(red: 0.55, green: 0.85, blue: 0.77)
        case "Newsletters", "News": return Color(red: 0.72, green: 0.76, blue: 0.86)
        default: return blue
        }
    }
}

struct GlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.34, blue: 0.53), Palette.background, Color(red: 0.10, green: 0.17, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.47, green: 0.61, blue: 0.83).opacity(0.3), .clear], center: .topTrailing, startRadius: 10, endRadius: 430)
        }.ignoresSafeArea()
    }
}

struct RootView: View {
    @EnvironmentObject var session: GoogleSession
    @EnvironmentObject var store: InboxStore
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    var body: some View {
        ZStack {
            GlassBackground()
            if session.accounts.isEmpty && !store.demo {
                WelcomeView()
            } else {
                SplitInboxView()
            }
        }
        .alert("Couldn’t complete that", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: phase) {
            guard phase == .active else { return }
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await store.refresh()
            }
        }
        .onChange(of: session.accounts) { _, _ in Task { await store.refresh() } }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var session: GoogleSession
    @EnvironmentObject var store: InboxStore
    @State private var signingIn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Palette.blue)
            Text("A little less noise.\nA little more space.").font(.system(size: 39, weight: .semibold, design: .rounded)).tracking(-1)
            Text("Your inbox, in focus.").font(.title3).foregroundStyle(Palette.blue)
            Text("Mail and calendar from your Google accounts, together. The same inbox on your Mac and your iPhone.").foregroundStyle(Palette.dim).lineSpacing(5)
            Spacer()
            Button {
                signingIn = true
                Task { defer { signingIn = false }; do { try await session.signIn() } catch { store.error = error.localizedDescription } }
            } label: {
                HStack { if signingIn { ProgressView() }; Text("Connect Google account").fontWeight(.semibold); Spacer(); Image(systemName: "arrow.right") }
                    .padding(18).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
            }.disabled(signingIn)
            Button("Explore with sample mail") { store.showDemo() }.frame(maxWidth: .infinity).padding(.bottom, 28)
        }.padding(28)
    }
}
