import MediaPlayer
import SwiftUI

/// A real Apple Music song picker. Presents the system media picker so the user picks
/// an actual song from their Apple Music / library; we keep only a `TrackRef`
/// (catalog id + title + artist + duration) — never the audio. Each viewer plays it
/// through their own Apple Music, so Kith shares the *reference*, not the file.
struct SongPicker: UIViewControllerRepresentable {
    var onPick: (TrackRefFfi) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = true
        picker.prompt = "Pick a song to play on your post"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: MPMediaPickerController, context: Context) {}

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let parent: SongPicker
        init(_ parent: SongPicker) { self.parent = parent }

        func mediaPicker(_ picker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            if let item = collection.items.first {
                // Apple Music catalog songs have a store id; library-only songs don't, so
                // fall back to the library persistent id (encoded as "lib:<id>") so they
                // still play on this device.
                let store = item.playbackStoreID
                let cid = (store.isEmpty || store == "0") ? "lib:\(item.persistentID)" : store
                parent.onPick(TrackRefFfi(
                    catalogId: cid,
                    title: item.title ?? "Unknown song",
                    artist: item.artist ?? "",
                    artworkUrl: "",
                    durationMs: UInt64(max(0, item.playbackDuration) * 1000)
                ))
            }
            parent.dismiss()
        }

        func mediaPickerDidCancel(_ picker: MPMediaPickerController) {
            parent.dismiss()
        }
    }
}
