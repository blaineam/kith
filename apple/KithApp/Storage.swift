import SwiftUI
import CryptoKit
import Security

/// Where the user's media is stored. iCloud is the default (their own quota); they can
/// also bring their own S3-compatible bucket, or connect a cloud drive over OAuth.
/// Crucially: Kith never hosts any API keys or client secrets — S3 keys live in the
/// Keychain on-device, and drive logins use OAuth 2.0 + PKCE (public clients, no secret).
enum StorageProvider: String, CaseIterable, Identifiable {
    case icloud, s3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icloud: return "Your iCloud"
        case .s3: return "Custom S3 bucket"
        }
    }
    var icon: String {
        switch self {
        case .icloud: return "icloud.fill"
        case .s3: return "externaldrive.fill"
        }
    }
}

@MainActor
final class StorageStore: ObservableObject {
    static let shared = StorageStore()

    @Published var provider: StorageProvider { didSet { d.set(provider.rawValue, forKey: "kith.storage.provider") } }
    @Published var s3Endpoint: String { didSet { d.set(s3Endpoint, forKey: "kith.s3.endpoint") } }
    @Published var s3Region: String { didSet { d.set(s3Region, forKey: "kith.s3.region") } }
    @Published var s3Bucket: String { didSet { d.set(s3Bucket, forKey: "kith.s3.bucket") } }
    @Published var s3AccessKey: String { didSet { Keychain.set(s3AccessKey, for: "s3AccessKey") } }
    @Published var s3Secret: String { didSet { Keychain.set(s3Secret, for: "s3Secret") } }
    /// "Volunteer as tribute": back up the circle's media (sealed to the circle, so it
    /// stays opaque to your storage provider) and re-serve it to members who are missing
    /// it — making your bucket a durable source for the whole circle.
    @Published var shareCircleMedia: Bool { didSet { d.set(shareCircleMedia, forKey: "kith.s3.share") } }

    private let d = UserDefaults.standard
    private init() {
        provider = StorageProvider(rawValue: d.string(forKey: "kith.storage.provider") ?? "") ?? .icloud
        s3Endpoint = d.string(forKey: "kith.s3.endpoint") ?? ""
        s3Region = d.string(forKey: "kith.s3.region") ?? "us-east-1"
        s3Bucket = d.string(forKey: "kith.s3.bucket") ?? ""
        s3AccessKey = Keychain.get("s3AccessKey") ?? ""
        s3Secret = Keychain.get("s3Secret") ?? ""
        shareCircleMedia = d.bool(forKey: "kith.s3.share")
    }

    var s3Configured: Bool { !s3Endpoint.isEmpty && !s3Bucket.isEmpty && !s3AccessKey.isEmpty && !s3Secret.isEmpty }
}

struct StorageSettingsView: View {
    @ObservedObject private var store = StorageStore.shared
    @ObservedObject private var mailbox = SharedMailboxStore.shared
    @State private var shared = false

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                if let cfg = mailbox.config {
                    Section {
                        Label("Connected to your circle's relay", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green).font(.subheadline.weight(.medium))
                        Text("Bucket: \(cfg.bucket) @ \(cfg.endpoint)").font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { SharedMailboxStore.shared.clear() } label: {
                            Text("Stop using this relay")
                        }
                    } header: { Text("Circle relay") }
                    footer: { Text("Your circle shares this bucket so posts arrive even when people are offline. Only sealed, unreadable blobs are stored there.") }
                }
                Section {
                    ForEach(StorageProvider.allCases) { p in
                        Button { store.provider = p } label: {
                            HStack {
                                Label(p.title, systemImage: p.icon).foregroundStyle(.primary)
                                Spacer()
                                if store.provider == p { Image(systemName: "checkmark").foregroundStyle(HavenTheme.pink) }
                            }
                        }
                    }
                } header: { Text("Where your media lives") }
                footer: { Text("Your media is end-to-end encrypted before it's stored anywhere. Haven never holds your keys or any provider secrets.") }

                if store.provider == .s3 { s3Section }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var s3Section: some View {
        Section {
            TextField("Endpoint (e.g. s3.amazonaws.com)", text: $store.s3Endpoint).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Region", text: $store.s3Region).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Bucket", text: $store.s3Bucket).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Access key id", text: $store.s3AccessKey).autocorrectionDisabled().textInputAutocapitalization(.never)
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
