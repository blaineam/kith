import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

#if !os(macOS)

/// A friendly photo/video picker (Photos library). Works in the Simulator, so the
/// whole attach → seal → feed path is verifiable without a camera. Returns media
/// refs registered in `MediaStore`.
struct MediaPicker: UIViewControllerRepresentable {
    var onPicked: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 30
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        private var finished = false
        init(_ parent: MediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Tapping "Add" more than once before the picker dismissed fired this delegate twice, so
            // every selected item was added to the post 2× (the doubled photos/videos). Process the
            // selection exactly once.
            guard !finished else { return }
            finished = true
            // Process ONE item at a time. Loading a big batch (e.g. 17 high-res photos) concurrently
            // decoded them all into memory at once and OOM-crashed (the post itself had already been
            // queued, so it still went through on relaunch). Serial keeps a single decoded frame
            // alive at a time, in the user's selection order.
            let providers = results.map(\.itemProvider)
            Task { @MainActor [weak self] in
                guard let self else { return }
                var refs: [String] = []
                for provider in providers {
                    if let ref = await Coordinator.loadRef(from: provider) { refs.append(ref) }
                }
                self.parent.onPicked(refs)
                self.parent.dismiss()
            }
        }

        /// Load a single picker item to a stored media ref, holding only one decoded item at a time.
        private static func loadRef(from provider: NSItemProvider) async -> String? {
            if provider.canLoadObject(ofClass: PlatformImage.self) {
                // Load the raw data (not just a decoded image) so we can read the EXIF GPS before
                // the bytes are re-encoded (which strips it). The coord stays on-device; it's only
                // shared if the author flips "Show location".
                let data: Data? = await withCheckedContinuation { cont in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in cont.resume(returning: d) }
                }
                guard let data, let img = PlatformImage(data: data) else {
                    // Fallback: some providers only vend a decoded image (no GPS available then).
                    let img: PlatformImage? = await withCheckedContinuation { cont in
                        provider.loadObject(ofClass: PlatformImage.self) { obj, _ in cont.resume(returning: obj as? PlatformImage) }
                    }
                    guard let img else { return nil }
                    return await MainActor.run { MediaStore.shared.addImage(img) }
                }
                let coord = MediaStore.gpsCoordinate(fromImageData: data)
                return await MainActor.run {
                    let ref = MediaStore.shared.addImage(img)
                    if let coord { MediaStore.shared.setLocation(coord, for: ref) }
                    return ref
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                let dest: URL? = await withCheckedContinuation { cont in
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        guard let url else { cont.resume(returning: nil); return }
                        // Copy out of the temporary location before it's reclaimed.
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                        try? FileManager.default.copyItem(at: url, to: dest)
                        cont.resume(returning: dest)
                    }
                }
                guard let dest else { return nil }
                return await MediaStore.shared.addVideo(url: dest)
            }
            return nil
        }
    }
}

#endif

#if os(macOS)

/// Native macOS photo/video picker. Mirrors the iOS `MediaPicker` signature exactly:
/// a single `onPicked: ([String]) -> Void` closure returning media refs registered in
/// `MediaStore`. PHPicker presentation differs on the Mac, so this uses `NSOpenPanel`.
struct MediaPicker: View {
    var onPicked: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .onAppear {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image, .movie]
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.canChooseFiles = true

                panel.begin { response in
                    guard response == .OK else {
                        dismiss()
                        return
                    }
                    let urls = panel.urls
                    Task { @MainActor in
                        var refs: [String] = []
                        for url in urls {
                            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                            if let type, type.conforms(to: .movie) {
                                refs.append(await MediaStore.shared.addVideo(url: url))
                            } else if let img = PlatformImage(contentsOf: url) {
                                refs.append(MediaStore.shared.addImage(img))
                            }
                        }
                        onPicked(refs)
                        dismiss()
                    }
                }
            }
    }
}

#endif
