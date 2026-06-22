import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
        init(_ parent: MediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let group = DispatchGroup()
            var refs: [String] = []
            let lock = NSLock()

            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        if let img = object as? UIImage {
                            Task { @MainActor in
                                let ref = MediaStore.shared.addImage(img)
                                lock.lock(); refs.append(ref); lock.unlock()
                                group.leave()
                            }
                        } else { group.leave() }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        guard let url else { group.leave(); return }
                        // Copy out of the temporary location before it's reclaimed.
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                        try? FileManager.default.copyItem(at: url, to: dest)
                        Task { @MainActor in
                            let ref = await MediaStore.shared.addVideo(url: dest)
                            lock.lock(); refs.append(ref); lock.unlock()
                            group.leave()
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                self.parent.onPicked(refs)
                self.parent.dismiss()
            }
        }
    }
}
