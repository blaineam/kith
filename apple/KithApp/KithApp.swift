import SwiftUI

@main
struct KithApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register the background-refresh task at launch (required before didFinishLaunching).
        NotificationManager.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { NotificationManager.shared.requestAuthorization() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { NotificationManager.shared.scheduleRefresh() }
        }
    }
}

struct RootView: View {
    @StateObject private var accountStore = AccountStore()
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var contacts = ContactsStore.shared

    @State private var tab = ProcessInfo.processInfo.environment["KITH_TAB"] ?? "circle"
    @State private var showConnect = false
    @State private var didPrompt = false
    @State private var pendingInvite: String?

    var body: some View {
        Group {
            if !profile.onboarded {
                OnboardingView(profile: profile)
                    .transition(.opacity)
            } else {
                main
            }
        }
        .animation(KithTheme.smooth, value: profile.onboarded)
        .onOpenURL { url in
            // Invite deep links: kith://u/<id>#<verify> (opened from wemiller.com/apps/kith).
            let s = url.absoluteString
            guard s.contains("/u/") else { return }
            pendingInvite = s
            tab = "you"
            showConnect = true
        }
    }

    private var main: some View {
        TabView(selection: $tab) {
            FeedView(seed: accountStore.account.secretSeed(), friendName: "Friend")
                .id(accountStore.account.nodeIdHex())
                .tag("circle")
                .tabItem { Label("Circle", systemImage: "sparkles") }
            YouView(
                account: accountStore.account,
                profile: profile,
                contacts: contacts,
                onReset: { accountStore.reset() }
            )
            .tag("you")
            .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
        }
        .tint(KithTheme.pink)
        .sheet(isPresented: $showConnect, onDismiss: { pendingInvite = nil }) {
            ConnectView(account: accountStore.account, contacts: contacts, incomingLink: pendingInvite)
        }
        .onAppear {
            FeedStore.shared.configure(seed: accountStore.account.secretSeed())
            if ProcessInfo.processInfo.environment["KITH_OPEN_CONNECT"] == "1" {
                showConnect = true
                return
            }
            // Gently walk first-time users into adding their first person.
            guard !didPrompt,
                  contacts.contacts.isEmpty,
                  ProcessInfo.processInfo.environment["KITH_SKIP_ONBOARDING"] != "1"
            else { return }
            didPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showConnect = true }
        }
    }
}
