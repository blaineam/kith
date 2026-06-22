import SwiftUI
import Photos

/// User preferences (on-device only).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: kSave) } }
    @Published var autoOptimize: Bool { didSet { d.set(autoOptimize, forKey: kOpt) } }
    /// Auto-delete posts older than this many days (0 = keep forever).
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: kRet) } }
    /// Global mute — silences post music + video audio so you can browse quietly.
    @Published var silent: Bool {
        didSet { d.set(silent, forKey: kSilent); AudioCoordinator.shared.setSilent(silent) }
    }
    /// Index your circle's posts into Spotlight (on-device search). Default OFF — opt-in,
    /// since it puts post text into the OS index (on-device only, never uploaded).
    @Published var spotlightEnabled: Bool {
        didSet {
            d.set(spotlightEnabled, forKey: kSpot)
            if spotlightEnabled { SpotlightIndex.reindexAll() } else { SpotlightIndex.clearAll() }
        }
    }

    private let d = UserDefaults.standard
    private let kSave = "haven.saveToPhotos"
    private let kOpt = "haven.autoOptimize"
    private let kRet = "haven.retentionDays"
    private let kSilent = "haven.silent"
    private let kSpot = "haven.spotlight"

    private init() {
        saveToPhotos = d.object(forKey: kSave) as? Bool ?? true   // default ON
        autoOptimize = d.object(forKey: kOpt) as? Bool ?? true
        retentionDays = d.object(forKey: kRet) as? Int ?? 0       // default forever
        silent = d.object(forKey: kSilent) as? Bool ?? false
        spotlightEnabled = d.object(forKey: kSpot) as? Bool ?? false   // default OFF
    }

    /// Viewer retention in seconds (nil = forever).
    var retentionSecs: UInt64? { retentionDays <= 0 ? nil : UInt64(retentionDays) * 86_400 }
}

/// Saves shared/received media into the user's Photos library so it's ready whenever
/// they open Photos. Add-only permission (the lightest). Honest privacy note: media
/// saved here leaves Kith's encrypted store for the user's own library, which may sync
/// to iCloud Photos — that's the user's choice, controlled by the toggle.
enum PhotoSaver {
    @MainActor
    static func saveIfEnabled(_ item: MediaItem) {
        guard SettingsStore.shared.saveToPhotos else { return }
        save(item)
    }

    static func save(_ item: MediaItem) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                if item.kind == .video, let url = item.videoURL {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else if let img = item.image {
                    PHAssetCreationRequest.creationRequestForAsset(from: img)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                Section {
                    Toggle("Silent mode", isOn: $settings.silent)
                        .tint(HavenTheme.pink)
                } footer: {
                    Text("Mute the whole app — post music and video sound stay quiet so you can browse silently. Also toggleable from the speaker button on your feed.")
                }
                Section {
                    Toggle("Save to Photos", isOn: $settings.saveToPhotos)
                        .tint(HavenTheme.pink)
                } footer: {
                    Text("Automatically save photos and videos you share or receive to your Photos library, so they're ready whenever you open Photos.")
                }
                Section {
                    Toggle("Auto-optimize media", isOn: $settings.autoOptimize)
                        .tint(HavenTheme.pink)
                } footer: {
                    Text("Share smaller, optimized photos and videos by default. Turn off to send pristine originals.")
                }
                Section {
                    Toggle("Index posts in Spotlight", isOn: $settings.spotlightEnabled)
                        .tint(HavenTheme.pink)
                } footer: {
                    Text("Find your circle's posts from system search. Off by default — when on, post text is added to the on-device Spotlight index (never uploaded).")
                }
                Section {
                    Picker("Auto-delete old posts", selection: $settings.retentionDays) {
                        Text("Off").tag(0)
                        Text("After 1 week").tag(7)
                        Text("After 1 month").tag(30)
                        Text("After 3 months").tag(90)
                        Text("After 1 year").tag(365)
                    }
                    .tint(HavenTheme.pink)
                } footer: {
                    Text("Automatically remove posts older than this from your feed. A sender can set a shorter limit on their own posts — the shorter one always wins.")
                }
                Section {
                    NavigationLink { StorageSettingsView() } label: {
                        Label("Storage", systemImage: "externaldrive.fill")
                    }
                } footer: {
                    Text("Choose where your encrypted media is stored — your iCloud, your own S3 bucket, or a connected cloud drive.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
