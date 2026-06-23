import Foundation
import Photos

/// Which Haven album a piece of media belongs in.
enum HavenAlbumKind {
    case shared    // media you created in-app (camera/story) and shared
    case received  // media other people sent you

    var title: String {
        switch self {
        case .shared: return "Shared"
        case .received: return "Received"
        }
    }
    fileprivate var defaultsKey: String {
        switch self {
        case .shared: return "haven.photos.album.shared"
        case .received: return "haven.photos.album.received"
        }
    }
}

/// Owns the Photos-library structure Haven saves into: a **"Haven" folder** containing a
/// **Shared** album and a **Received** album.
///
/// Everything is addressed by the collections' **local identifiers** (persisted), never by
/// title or position — so if the user drags the Haven folder under one of their own folders,
/// or renames it, we still resolve and keep adding to the same albums. If the user deletes a
/// collection, the saved identifier stops resolving and we transparently recreate it.
final class HavenPhotoAlbums {
    static let shared = HavenPhotoAlbums()
    private let d = UserDefaults.standard
    private let folderKey = "haven.photos.folder"
    private let queue = DispatchQueue(label: "haven.photos.albums")

    /// Resolve (creating if needed) the album collection for a kind, on a background queue.
    func collection(for kind: HavenAlbumKind, _ completion: @escaping (PHAssetCollection?) -> Void) {
        queue.async {
            if let existing = self.existingAlbum(kind) {
                completion(existing); return
            }
            self.createStructure {
                completion(self.existingAlbum(kind))
            }
        }
    }

    // MARK: Resolve

    private func existingAlbum(_ kind: HavenAlbumKind) -> PHAssetCollection? {
        guard let id = d.string(forKey: kind.defaultsKey) else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func existingFolder() -> PHCollectionList? {
        guard let id = d.string(forKey: folderKey) else { return nil }
        return PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: Create

    /// Create whatever's missing — the Haven folder and either album — in one change request,
    /// then persist the resulting local identifiers. Safe to call repeatedly; only missing
    /// pieces are created.
    private func createStructure(_ completion: @escaping () -> Void) {
        let folder = existingFolder()
        let needShared = existingAlbum(.shared) == nil
        let needReceived = existingAlbum(.received) == nil

        // Nothing to do (e.g. another caller just created them).
        if folder != nil, !needShared, !needReceived { completion(); return }

        var folderPlaceholderId: String?
        var sharedPlaceholderId: String?
        var receivedPlaceholderId: String?

        PHPhotoLibrary.shared().performChanges {
            // The folder (PHCollectionList) — reuse the existing one or make it.
            let folderRequest: PHCollectionListChangeRequest
            if let folder {
                folderRequest = PHCollectionListChangeRequest(for: folder)!
            } else {
                let req = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: "Haven")
                folderPlaceholderId = req.placeholderForCreatedCollectionList.localIdentifier
                folderRequest = req
            }

            var newChildren: [PHObjectPlaceholder] = []
            if needShared {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: HavenAlbumKind.shared.title)
                sharedPlaceholderId = req.placeholderForCreatedAssetCollection.localIdentifier
                newChildren.append(req.placeholderForCreatedAssetCollection)
            }
            if needReceived {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: HavenAlbumKind.received.title)
                receivedPlaceholderId = req.placeholderForCreatedAssetCollection.localIdentifier
                newChildren.append(req.placeholderForCreatedAssetCollection)
            }
            if !newChildren.isEmpty {
                folderRequest.addChildCollections(newChildren as NSArray)
            }
        } completionHandler: { ok, _ in
            if ok {
                if let folderPlaceholderId { self.d.set(folderPlaceholderId, forKey: self.folderKey) }
                if let sharedPlaceholderId { self.d.set(sharedPlaceholderId, forKey: HavenAlbumKind.shared.defaultsKey) }
                if let receivedPlaceholderId { self.d.set(receivedPlaceholderId, forKey: HavenAlbumKind.received.defaultsKey) }
            }
            completion()
        }
    }
}
