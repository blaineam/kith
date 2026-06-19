import SwiftUI

@main
struct KithApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var accountStore = AccountStore()
    @StateObject private var profile = ProfileStore()
    @StateObject private var contacts = ContactsStore()

    @State private var tab = ProcessInfo.processInfo.environment["KITH_TAB"] ?? "circle"
    @State private var showConnect = false
    @State private var didPrompt = false

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
    }

    private var main: some View {
        TabView(selection: $tab) {
            FeedView(seed: accountStore.account.secretSeed(), friendName: "Sam")
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
        .sheet(isPresented: $showConnect) {
            ConnectView(account: accountStore.account, contacts: contacts)
        }
        .onAppear {
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
