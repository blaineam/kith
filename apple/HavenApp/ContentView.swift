import SwiftUI
import UIKit

/// The friendly "You" screen: who you are, your circle, and an easy way to invite
/// people. The technical bits live behind "Advanced".
struct YouView: View {
    let account: Account
    let accountStore: AccountStore
    @ObservedObject var profile: ProfileStore
    @ObservedObject var contacts: ContactsStore
    @ObservedObject private var feed = FeedStore.shared
    var onReset: () -> Void

    @State private var showConnect = false
    @State private var showEditProfile = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        profileHeader.entrance(appeared, delay: 0.00)
                        inviteButton.entrance(appeared, delay: 0.06)
                        NavigationLink { CircleView(account: account) } label: { circleCard }
                            .buttonStyle(.plain)
                            .entrance(appeared, delay: 0.12)
                        NavigationLink { ProfileView(friendName: "Friend") } label: {
                            HStack {
                                Label("Your posts", systemImage: "square.stack.fill")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .kithCard()
                        .entrance(appeared, delay: 0.15)
                        privacyCard.entrance(appeared, delay: 0.18)
                        NavigationLink {
                            SettingsView()
                        } label: {
                            HStack {
                                Label("Settings", systemImage: "gearshape.fill")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .kithCard()
                        .entrance(appeared, delay: 0.22)
                        NavigationLink {
                            AdvancedView(account: account, accountStore: accountStore, onReset: onReset)
                        } label: {
                            Label("Advanced", systemImage: "wrench.and.screwdriver")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .entrance(appeared, delay: 0.28)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $showConnect) {
                ConnectView(account: account, contacts: contacts)
            }
            .sheet(isPresented: $showEditProfile) { EditProfileSheet() }
            .onAppear { withAnimation(HavenTheme.smooth) { appeared = true } }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 10) {
            Button { showEditProfile = true } label: {
                HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 92)
                    .shadow(color: HavenTheme.pink.opacity(0.35), radius: 16, y: 8)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3).foregroundStyle(HavenTheme.pink)
                            .background(Circle().fill(.background))
                    }
            }
            .buttonStyle(.plain)
            Text(profile.displayName.isEmpty ? "You" : profile.displayName)
                .font(.title2.bold())
            Text("This is just for the people you choose.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var inviteButton: some View {
        Button { showConnect = true } label: {
            Label("Invite a friend", systemImage: "person.badge.plus")
        }
        .buttonStyle(BrandButtonStyle())
    }

    private var circleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your circle").font(.headline)
                Spacer()
                Label("Manage", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.tertiary)
            }
            if contacts.contacts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2).foregroundStyle(HavenTheme.pink)
                    Text("It's just you for now. Invite someone you love to get started.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ForEach(contacts.contacts) { c in
                    let connected = feed.isConnected(c.idHex)
                    HStack(spacing: 12) {
                        Circle().fill(HavenTheme.brand).frame(width: 34, height: 34)
                            .overlay(Text(String(c.displayName.prefix(1))).font(.caption.bold()).foregroundStyle(.white))
                        Text(c.displayName).font(.subheadline.weight(.medium))
                        Spacer()
                        HStack(spacing: 5) {
                            Circle().fill(connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                            Text(connected ? "Connected" : "Waiting to connect")
                                .font(.caption2).foregroundStyle(connected ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kithCard()
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your circle is private").font(.subheadline.weight(.semibold))
                Text("Everything you share is locked so only your people can see it. No ads, no tracking — ever.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kithCard()
    }
}

/// Tucked-away technical details for the curious.
struct AdvancedView: View {
    let account: Account
    let accountStore: AccountStore
    var onReset: () -> Void

    @State private var report: SelfTestReport?
    @State private var runCount = 0
    @State private var showResetConfirm = false
    @State private var iCloudSync = AccountStore.iCloudSyncEnabled

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    detailsCard
                    privacyCheckCard
                    NavigationLink { ConnectionView() } label: {
                        HStack {
                            Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .kithCard()
                    NavigationLink { BlockedPeopleView() } label: {
                        HStack {
                            Label("Blocked people", systemImage: "hand.raised.fill")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .kithCard()
                    identityCard
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Start over (new identity)", systemImage: "arrow.counterclockwise")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(20)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(trigger: runCount) { _, _ in report?.allOk == true ? .success : .error }
        .confirmationDialog("Start over with a brand-new identity?",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Erase everything & start over", role: .destructive) {
                onReset()
                report = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases your identity, your whole circle, and every post on this device — and the people you've connected with will no longer recognize you. This can't be undone.")
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your identity on your devices").font(.headline)
            Toggle(isOn: $iCloudSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Sync across my Apple devices", systemImage: "icloud.fill").font(.subheadline.weight(.medium))
                    Text("Use the same identity on your iPhone, iPad, and Mac via iCloud Keychain (end-to-end encrypted by Apple).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(HavenTheme.pink)
            .onChange(of: iCloudSync) { _, on in accountStore.setICloudSync(on) }
            Divider()
            NavigationLink { TransferIdentityView(accountStore: accountStore) } label: {
                HStack {
                    Label("Move to another device", systemImage: "qrcode").font(.subheadline.weight(.medium))
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            NavigationLink { RestoreIdentityView(accountStore: accountStore, onRestored: {}) } label: {
                HStack {
                    Label("Restore identity here", systemImage: "arrow.down.circle").font(.subheadline.weight(.medium))
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kithCard()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Under the hood").font(.headline)
            row("Your id", String(account.nodeIdHex().prefix(24)) + "…")
            row("Safety words", SafetyWords.words(fromHex: account.verificationHex()).joined(separator: " · "))
            Text("Haven uses hybrid post-quantum encryption (X25519 + ML-KEM-768, Ed25519 + ML-DSA). Your keys never leave this device.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kithCard()
    }

    private var privacyCheckCard: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(HavenTheme.bouncy) { report = selfTest(); runCount += 1 }
            } label: {
                Label("Run privacy check", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HavenTheme.pink)
                    .padding(.vertical, 13).frame(maxWidth: .infinity)
                    .background(Capsule().strokeBorder(HavenTheme.brandHorizontal, lineWidth: 1.5))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("privacyCheck")

            if let r = report {
                VStack(spacing: 10) {
                    checkRow("Identity is yours", r.identityOk, 0)
                    checkRow("Your stuff is locked (seal → open)", r.hybridKemOk, 1)
                    checkRow("Messages are signed", r.signatureOk, 2)
                    checkRow("Invite links are safe", r.linkOk, 3)
                    Divider()
                    Label(r.summary, systemImage: r.allOk ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(r.allOk ? .green : .red)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .kithCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced()).multilineTextAlignment(.trailing)
        }
    }

    private func checkRow(_ title: String, _ ok: Bool, _ index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red).imageScale(.large)
            Text(title).font(.subheadline)
            Spacer()
        }
        .opacity(report != nil ? 1 : 0)
        .offset(x: report != nil ? 0 : -16)
        .animation(HavenTheme.bouncy.delay(Double(index) * 0.08), value: runCount)
    }
}

/// Staggered slide-up entrance for a section.
struct Entrance: ViewModifier {
    let shown: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .animation(HavenTheme.smooth.delay(delay), value: shown)
    }
}

extension View {
    func entrance(_ shown: Bool, delay: Double) -> some View {
        modifier(Entrance(shown: shown, delay: delay))
    }
}
