import SwiftUI
import Photos

/// User preferences (on-device only).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: kSave) } }
    @Published var autoOptimize: Bool { didSet { d.set(autoOptimize, forKey: kOpt) } }

    private let d = UserDefaults.standard
    private let kSave = "kith.saveToPhotos"
    private let kOpt = "kith.autoOptimize"

    private init() {
        saveToPhotos = d.object(forKey: kSave) as? Bool ?? true   // default ON
        autoOptimize = d.object(forKey: kOpt) as? Bool ?? true
    }
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
            KithBackground()
            Form {
                Section {
                    Toggle("Save to Photos", isOn: $settings.saveToPhotos)
                        .tint(KithTheme.pink)
                } footer: {
                    Text("Automatically save photos and videos you share or receive to your Photos library, so they're ready whenever you open Photos.")
                }
                Section {
                    Toggle("Auto-optimize media", isOn: $settings.autoOptimize)
                        .tint(KithTheme.pink)
                } footer: {
                    Text("Share smaller, optimized photos and videos by default. Turn off to send pristine originals.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
