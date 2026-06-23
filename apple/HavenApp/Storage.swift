import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import CryptoKit
import Security

/// Where the user's media is stored. iCloud is the default (their own quota); they can
/// also bring their own S3-compatible bucket, or connect a cloud drive over OAuth.
/// Crucially: Haven never hosts any API keys or client secrets — S3 keys live in the
/// Keychain on-device, and drive logins use OAuth 2.0 + PKCE (public clients, no secret).
enum StorageProvider: String, CaseIterable, Identifiable {
    case s3   // iCloud removed: Apple-only + never wired for sharing. Relay (toggle) or S3 only.
    var id: String { rawValue }
    var title: String { "Custom S3 bucket" }
    var icon: String { "externaldrive.fill" }
}

@MainActor
final class StorageStore: ObservableObject {
    static let shared = StorageStore()

    @Published var provider: StorageProvider { didSet { d.set(provider.rawValue, forKey: "haven.storage.provider") } }
    @Published var s3Endpoint: String { didSet { d.set(s3Endpoint, forKey: "haven.s3.endpoint") } }
    @Published var s3Region: String { didSet { d.set(s3Region, forKey: "haven.s3.region") } }
    @Published var s3Bucket: String { didSet { d.set(s3Bucket, forKey: "haven.s3.bucket") } }
    @Published var s3AccessKey: String { didSet { Keychain.set(s3AccessKey, for: "s3AccessKey") } }
    @Published var s3Secret: String { didSet { Keychain.set(s3Secret, for: "s3Secret") } }
    /// "Volunteer as tribute": back up the circle's media (sealed to the circle, so it
    /// stays opaque to your storage provider) and re-serve it to members who are missing
    /// it — making your bucket a durable source for the whole circle.
    @Published var shareCircleMedia: Bool { didSet { d.set(shareCircleMedia, forKey: "haven.s3.share") } }

    private let d = UserDefaults.standard
    private init() {
        provider = .s3
        s3Endpoint = d.string(forKey: "haven.s3.endpoint") ?? ""
        s3Region = d.string(forKey: "haven.s3.region") ?? "us-east-1"
        s3Bucket = d.string(forKey: "haven.s3.bucket") ?? ""
        s3AccessKey = Keychain.get("s3AccessKey") ?? ""
        s3Secret = Keychain.get("s3Secret") ?? ""
        shareCircleMedia = d.bool(forKey: "haven.s3.share")
    }

    var s3Configured: Bool { !s3Endpoint.isEmpty && !s3Bucket.isEmpty && !s3AccessKey.isEmpty && !s3Secret.isEmpty }
}

struct StorageSettingsView: View {
    /// The circle being configured (nil = the active circle, for the global Settings entry).
    var circleId: String? = nil
    @ObservedObject private var mailbox = SharedMailboxStore.shared
    @ObservedObject private var relay = RelayHost.shared
    @State private var relayAdopted = false
    @State private var startAtLogin = false
    @State private var loginItemError: String?

    private var cid: String { circleId ?? FeedStore.shared.activeCircleId }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                // The common path: make this device the circle's mailbox with one toggle.
                Section {
                    Toggle(isOn: Binding(get: { relay.enabled }, set: { relay.setEnabled($0) })) {
                        Label("Be your circle's relay", systemImage: "externaldrive.connected.to.line.below.fill")
                    }
                    .tint(HavenTheme.pink)
                    if relay.serving && !relay.nodeId.isEmpty {
                        Label("Relaying for your circles · \(String(relay.nodeId.prefix(8)))…", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if relay.enabled {
                        Label("Starting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    // Mac-only: keep the relay always-on by relaunching Haven at login. Catalyst
                    // can't run a true headless/menu-bar agent, so the best achievable is to
                    // auto-launch at login and keep relaying for the life of the process — leave a
                    // Haven window open (it can stay in the background) and the relay keeps serving.
                    if relay.enabled && relay.loginItemSupported {
                        Toggle(isOn: Binding(get: { startAtLogin }, set: { setStartAtLogin($0) })) {
                            Label("Start Haven at login (keep the relay running)", systemImage: "power")
                        }
                        .tint(HavenTheme.pink)
                        if let err = loginItemError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text("With this on, Haven relays invisibly in the background: close the window and it keeps serving your circle with no dock icon (launch Haven again to reopen it). At login it starts hidden — launch it a second time to open the window, like the first time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Circle relay")
                } footer: {
                    Text(relay.isDesktopClass
                         ? "Turn this Mac into your circles' always-available mailbox — sealed (unreadable) posts and media are stored here and re-served to your circle whenever someone's been offline. Just leave Haven running."
                         : "Use this device as your circles' mailbox — sealed posts/media live here and re-serve when someone's offline. On iPhone/iPad it serves while Haven is open and the screen's on (keep it on a charger); a Mac or the desktop app is best for always-on. No setup, no cloud.")
                }
                // Reuse a mailbox you already set up on another circle — a simple one-tap pick.
                let others = RelayMailboxStore.shared.circlesWithRelay(excluding: cid)
                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.self) { other in
                            if let node = RelayMailboxStore.shared.explicitNode(forCircle: other) {
                                Button {
                                    FeedStore.shared.adoptRelayNode(node, circleIds: [cid], setDefault: false)
                                    relayAdopted = true
                                } label: {
                                    HStack {
                                        Label(FeedStore.shared.circles.first { $0.id == other }?.name ?? "Another circle",
                                              systemImage: "arrow.triangle.2.circlepath")
                                        Spacer()
                                        Text("\(node.prefix(8))…").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if relayAdopted {
                            Label("Connected — used as the mailbox", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    } header: { Text("Use another circle's mailbox") }
                    footer: { Text("Point this circle at a relay you already connected for a different circle.") }
                }

                if let cfg = mailbox.config {
                    Section {
                        Label("Connected to your circle's relay", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green).font(.subheadline.weight(.medium))
                        Text("Bucket: \(cfg.bucket) @ \(cfg.endpoint)").font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { SharedMailboxStore.shared.clear() } label: {
                            Text("Stop using this relay")
                        }
                    } header: { Text("Active mailbox") }
                    footer: { Text("Your circle shares this bucket so posts arrive even when people are offline. Only sealed, unreadable blobs are stored there.") }
                }

                // Power-user options live one tap deeper so the common path stays uncluttered:
                // connecting an external relay daemon by node id, or bringing your own S3 bucket.
                Section {
                    NavigationLink {
                        AdvancedStorageView(circleId: circleId)
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Connect an external always-on relay (a Mac, Linux box, or spare device running `haven-relay`), or point Haven at your own S3-compatible bucket. Optional — the toggle above is all most people need.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Storage")
        .havenInlineNavTitle()
        .onAppear { startAtLogin = relay.startsAtLogin }
    }

    /// Register/unregister Haven as a macOS login item, reflecting the real status back into the
    /// toggle and surfacing any error (e.g. unsigned dev build) instead of crashing.
    private func setStartAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            try relay.setStartAtLogin(on)
        } catch {
            loginItemError = "Couldn't \(on ? "enable" : "disable") start-at-login: \(error.localizedDescription)"
        }
        // Reflect the OS's actual state (the user may have it disabled in System Settings).
        startAtLogin = relay.startsAtLogin
    }

}

/// Power-user storage, one tap below the simple relay toggle on the Storage screen: connect an
/// external `haven-relay` daemon by node id, or bring your own S3-compatible bucket. Kept off the
/// main screen so the common path (flip "Be your circle's relay") stays clean — advanced users
/// drill in when they need it.
struct AdvancedStorageView: View {
    var circleId: String? = nil
    @ObservedObject private var store = StorageStore.shared
    @State private var relayNodeInput = ""
    @State private var relayAdopted = false
    @State private var linkCopied = false
    @State private var applyToAll = true
    @State private var shared = false

    private var cid: String { circleId ?? FeedStore.shared.activeCircleId }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                // Connect an external always-on relay daemon (Mac/Linux/an old device running
                // `haven-relay`): hand it this circle's link, then paste back the node id it prints
                // so the whole circle adopts it.
                Section {
                    Button {
                        if let link = FeedStore.shared.relayLink() {
                            PlatformPasteboard.string = link
                            linkCopied = true
                        }
                    } label: {
                        Label(linkCopied ? "Copied — run: haven-relay run --link …" : "1. Copy this circle's relay link",
                              systemImage: linkCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(linkCopied ? Color.green : HavenTheme.pink)
                    }
                    TextField("2. Paste the daemon's node id (64 hex)", text: $relayNodeInput)
                        .autocorrectionDisabled().havenAutocap(.never)
                        .font(.system(.footnote, design: .monospaced))
                    Toggle("Use for all my circles (now & future)", isOn: $applyToAll).tint(HavenTheme.pink)
                    Button {
                        let id = relayNodeInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return }
                        let targets = applyToAll ? FeedStore.shared.circles.map(\.id) : [cid]
                        FeedStore.shared.adoptRelayNode(id, circleIds: targets, setDefault: applyToAll)
                        relayAdopted = true; relayNodeInput = ""
                    } label: {
                        Label(applyToAll ? "Connect for all my circles" : "Connect for this circle",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(relayNodeInput.trimmingCharacters(in: .whitespacesAndNewlines).count != 64)
                    if relayAdopted {
                        Label("Connected — used as the mailbox", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                } header: { Text("Connect an external relay") }
                footer: {
                    Text("Running `haven-relay` on a Mac, Linux box, or a spare device? Copy the link above and start it with `haven-relay run --link <link>`, then paste back the node id it shows (`haven-relay id`). No cloud, no credentials.")
                }

                Section {
                    Text("Bring your own S3-compatible bucket instead: your key stays on this device and the circle gets scoped, expiring **pre-signed URLs**, never the secret.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Your own S3 bucket") }

                s3Section
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Advanced")
        .havenInlineNavTitle()
    }

    @ViewBuilder private var s3Section: some View {
        Section {
            TextField("Endpoint (e.g. s3.amazonaws.com)", text: $store.s3Endpoint).autocorrectionDisabled().havenAutocap(.never)
            TextField("Region", text: $store.s3Region).autocorrectionDisabled().havenAutocap(.never)
            TextField("Bucket", text: $store.s3Bucket).autocorrectionDisabled().havenAutocap(.never)
            TextField("Access key id", text: $store.s3AccessKey).autocorrectionDisabled().havenAutocap(.never)
            SecureField("Secret access key", text: $store.s3Secret)
            if store.s3Configured {
                Label("Saved on this device", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
            }
        } header: { Text("Your S3-compatible bucket") }
        footer: { Text("Works with AWS S3, Cloudflare R2, Backblaze B2, rclone serve s3, etc. Keys are stored only in this device's Keychain — never on any server.") }

        if store.s3Configured {
            Section {
                Toggle(isOn: $store.shareCircleMedia) {
                    Label("Be the circle's backup", systemImage: "heart.circle.fill")
                }
                .tint(HavenTheme.pink)
                Button {
                    FeedStore.shared.shareBucketWithCircle(); shared = true
                } label: {
                    Label(shared ? "Shared with your circle ✓" : "Share this bucket as my circle's relay",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
                .tint(HavenTheme.pink)
            } header: { Text("Volunteer as tribute") }
            footer: { Text("Your bucket becomes the circle's shared mailbox: every post is stored sealed and re-served to anyone who's missing it — so messages and memories arrive even when the sender is offline and you're never online at the same time. Tap “Share as my circle's relay” to send these credentials (sealed, only your circle can open them) so everyone uses the same bucket — rent one from any S3 provider, no server to run. Heads up: members you share with can read (still sealed) and write to the bucket, so only share with a circle you trust, and rotate the key if someone leaves.") }
        }
    }
}

/// OAuth 2.0 PKCE helpers (public client — no secret). Retained for a future
/// cloud-drive integration; not wired to any provider today (iCloud + S3 only).
enum PKCE {
    static func verifier() -> String { base64url(randomBytes(32)) }
    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal Keychain string store for storage credentials/tokens.
enum Keychain {
    private static let service = "com.blaineam.kith.storage"
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
