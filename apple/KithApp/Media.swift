import SwiftUI
import AVFoundation
import UIKit

enum MediaKind: String { case image, video }

/// A piece of attached media held locally on this device. In the real send path the
/// underlying bytes are sealed E2E before they leave; here (local demo) they stay on
/// device only — nothing is uploaded anywhere.
struct MediaItem: Identifiable {
    let id: String
    let kind: MediaKind
    let image: UIImage?   // the photo, or a video's poster frame
    let videoURL: URL?
}

/// In-memory map of media-ref → MediaItem, so the feed can render attachments by ref.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()
    private var items: [String: MediaItem] = [:]

    @discardableResult
    func addImage(_ image: UIImage) -> String {
        let id = UUID().uuidString
        items[id] = MediaItem(id: id, kind: .image, image: image, videoURL: nil)
        return id
    }

    @discardableResult
    func addVideo(url: URL) -> String {
        let id = UUID().uuidString
        items[id] = MediaItem(id: id, kind: .video, image: Self.poster(for: url), videoURL: url)
        return id
    }

    func item(_ ref: String) -> MediaItem? { items[ref] }

    /// Extract a poster frame so videos show something before playback.
    static func poster(for url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
