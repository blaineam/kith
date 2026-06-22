import SwiftUI

/// Receives the APNs device token + remote-notification wakes (SwiftUI App needs a delegate
/// for these callbacks).
final class HavenAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.registered(deviceToken: deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in FeedStore.shared.forceSync(); completionHandler(.newData) }
    }
}

@main
struct HavenApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(HavenAppDelegate.self) private var appDelegate

    init() {
        // Register the background-refresh task at launch (required before didFinishLaunching).
        NotificationManager.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    NotificationManager.shared.requestAuthorization()
                    PushManager.shared.start()   // register for real push via the relay
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                NotificationManager.shared.scheduleRefresh()
                AudioCoordinator.shared.pauseForBackground()   // don't keep playing audio in the background
            }
        }
    }
}

/// An incoming invite link, wrapped so it can drive an item-based sheet.
struct PendingInvite: Identifiable {
    let id = UUID()
    let link: String
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var accountStore = AccountStore()
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @ObservedObject private var feedStore = FeedStore.shared
    @ObservedObject private var connections = ConnectionsStore.shared

    @State private var tab = ProcessInfo.processInfo.environment["HAVEN_TAB"] ?? "circle"
    @State private var showConnect = false
    @State private var didPrompt = false
    /// An incoming invite link. Driving the sheet from this *item* (not a separate bool)
    /// guarantees the ConnectView gets the link on the first open — `.sheet(isPresented:)`
    /// with a separate state captured a stale (nil) link, which is why it took two taps.
    @State private var pendingInvite: PendingInvite?

    var body: some View {
        Group {
            if !profile.onboarded {
                OnboardingView(profile: profile, accountStore: accountStore)
                    .transition(.opacity)
            } else {
                main
            }
        }
        .animation(HavenTheme.smooth, value: profile.onboarded)
        .onOpenURL { url in
            // Invite deep links: haven://u/<id>#<verify> (opened from wemiller.com/apps/haven).
            let s = url.absoluteString
            guard s.contains("/u/") else { return }
            tab = "you"
            pendingInvite = PendingInvite(link: s)   // item-driven sheet → correct on first open
        }
    }

    private var main: some View {
        TabView(selection: $tab) {
            FeedView(seed: accountStore.account.secretSeed(), friendName: "Friend")
                .id(accountStore.account.nodeIdHex())
                .tag("circle")
                .tabItem { Label("Circle", systemImage: "sparkles") }
                .badge(feedStore.unseenCircle)
            NavigationStack { MessagesView(account: accountStore.account) }
                .tag("messages")
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(feedStore.unseenMessages)
            YouView(
                account: accountStore.account,
                accountStore: accountStore,
                profile: profile,
                contacts: contacts,
                onReset: { accountStore.reset() }
            )
            .tag("you")
            .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
            .badge(connections.pending.count)
        }
        .tint(HavenTheme.pink)
        .onChange(of: tab) { _, t in
            if t == "circle" { feedStore.markCircleSeen() }
            if t == "messages" { feedStore.markMessagesSeen() }
        }
        .overlay {
            CallOverlay()
                .animation(HavenTheme.smooth, value: CallManager.shared.connecting)
                .animation(HavenTheme.smooth, value: CallManager.shared.inCall)
                .animation(HavenTheme.smooth, value: CallManager.shared.ringing)
        }
        // Manual "add a friend" (onboarding / the + button) — no incoming link.
        .sheet(isPresented: $showConnect) {
            ConnectView(account: accountStore.account, contacts: contacts, incomingLink: nil)
        }
        // Invite deep link — the item carries the link, so ConnectView gets it immediately.
        .sheet(item: $pendingInvite) { invite in
            ConnectView(account: accountStore.account, contacts: contacts, incomingLink: invite.link)
        }
        .onChange(of: scenePhase) { _, phase in
            // If we booted before the keychain was readable, swap the real identity back in
            // once we're active + unlocked (never silently keeps a throwaway identity).
            if phase == .active { accountStore.reloadIfTemporary() }
        }
        .onAppear {
            accountStore.reloadIfTemporary()
            FeedStore.shared.configure(seed: accountStore.account.secretSeed())
            if ProcessInfo.processInfo.environment["HAVEN_OPEN_CONNECT"] == "1" {
                showConnect = true
                return
            }
            // Gently walk first-time users into adding their first person.
            guard !didPrompt,
                  contacts.contacts.isEmpty,
                  ProcessInfo.processInfo.environment["HAVEN_SKIP_ONBOARDING"] != "1"
            else { return }
            didPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showConnect = true }
        }
    }
}
