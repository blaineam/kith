import MediaPlayer
import SwiftUI

/// Parse a track's encoded id "<storeID>~<persistentID>" (either part may be absent).
func trackIds(_ catalogId: String) -> (store: String?, pid: UInt64?) {
    let parts = catalogId.split(separator: "~", maxSplits: 1, omittingEmptySubsequences: false)
    let store = parts.first.map(String.init).flatMap { ($0.isEmpty || $0 == "0") ? nil : $0 }
    let pid = parts.count > 1 ? UInt64(parts[1]) : nil
    return (store, pid)
}

/// The exact library song matching a persistent id, if it exists on this device.
@MainActor func librarySong(_ pid: UInt64) -> MPMediaItem? {
    let q = MPMediaQuery.songs()
    q.addFilterPredicate(MPMediaPropertyPredicate(value: pid, forProperty: MPMediaItemPropertyPersistentID))
    return q.items?.first
}

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
                // Encode BOTH ids: the catalog store id (universal — lets the recipient
                // play it from their own Apple Music) and the library persistent id (an
                // exact local match for the sender). Format: "<storeID>~<persistentID>".
                let cid = "\(item.playbackStoreID)~\(item.persistentID)"
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
