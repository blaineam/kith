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
            // BLOCK the serial queue until creation actually finishes + the ids persist. Otherwise this
            // block returned immediately (createStructure's performChanges is async), so a burst of saves
            // (e.g. a batch of received photos) each saw "no album yet" and each created a whole new
            // "Haven" folder → dozens of duplicates. The semaphore serializes creation to exactly once.
            let sem = DispatchSemaphore(value: 0)
            self.createStructure { sem.signal() }
            sem.wait()
            completion(self.existingAlbum(kind))
        }
    }

    // MARK: Resolve

    private func existingAlbum(_ kind: HavenAlbumKind) -> PHAssetCollection? {
        // 1) By persisted local id (survives renames/moves).
        if let id = d.string(forKey: kind.defaultsKey),
           let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
            return c
        }
        // 2) Fall back to an album of this title ALREADY INSIDE the Haven folder, and adopt it — so we
        //    reuse a structure that's already present instead of creating a parallel one.
        if let folder = existingFolder() {
            var found: PHAssetCollection?
            PHCollectionList.fetchCollections(in: folder, options: nil).enumerateObjects { obj, _, stop in
                if let a = obj as? PHAssetCollection, a.localizedTitle == kind.title { found = a; stop.pointee = true }
            }
            if let found { d.set(found.localIdentifier, forKey: kind.defaultsKey); return found }
        }
        return nil
    }

    private func existingFolder() -> PHCollectionList? {
        // 1) By persisted local id.
        if let id = d.string(forKey: folderKey),
           let f = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject {
            return f
        }
        // 2) Fall back to ANY existing top-level folder titled "Haven" and adopt it, so we don't add a
        //    parallel one next to a Haven folder the user already has.
        var found: PHCollectionList?
        PHCollectionList.fetchCollectionLists(with: .folder, subtype: .regularFolder, options: nil).enumerateObjects { f, _, stop in
            if f.localizedTitle == "Haven" { found = f; stop.pointee = true }
        }
        if let found { d.set(found.localIdentifier, forKey: folderKey) }
        return found
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
