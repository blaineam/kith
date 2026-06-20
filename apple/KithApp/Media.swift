import SwiftUI
import AVFoundation
import UIKit

enum MediaKind: String {
    case image, video, audio
    var ext: String {
        switch self {
        case .image: return "jpg"
        case .video: return "mp4"
        case .audio: return "m4a"
        }
    }
    /// The kind is encoded in the ref prefix so a recipient knows how to render it.
    init?(ref: String) {
        if ref.hasPrefix("img_") { self = .image }
        else if ref.hasPrefix("vid_") { self = .video }
        else if ref.hasPrefix("aud_") { self = .audio }
        else { return nil }
    }
}

/// A piece of attached media held locally. Bytes are persisted to disk (so they
/// survive restarts) and are sealed E2E before they ever leave the device.
struct MediaItem: Identifiable {
    let id: String
    let kind: MediaKind
    let image: UIImage?   // the photo, or a video's poster frame
    let videoURL: URL?
}

/// Persistent, content-ref'd media store. Refs encode the kind (img_/vid_/aud_) so a
/// recipient who receives the bytes can reconstruct the item. Files live under
/// Application Support/kith-media so they survive app restarts and updates.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()
    private var cache: [String: MediaItem] = [:]

    private var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kith-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func fileURL(_ ref: String) -> URL? {
        guard let kind = MediaKind(ref: ref) else { return nil }
        return dir.appendingPathComponent("\(ref).\(kind.ext)")
    }

    @discardableResult
    func addImage(_ image: UIImage) -> String {
        let ref = "img_\(UUID().uuidString)"
        // Optimize: downscale very large photos + compress, so they're light to send —
        // but keep it high-res (longest edge up to 2560, well above 1080p).
        let optimize = SettingsStore.shared.autoOptimize
        let img = optimize ? Self.downscale(image, maxDimension: 2560) : image
        let quality: CGFloat = optimize ? 0.88 : 0.95
        if let data = img.jpegData(compressionQuality: quality), let url = fileURL(ref) {
            try? data.write(to: url)
        }
        cache[ref] = MediaItem(id: ref, kind: .image, image: img, videoURL: nil)
        return ref
    }

    /// Async because optimizing transcodes the video (AVAssetExportSession). Without
    /// this, full-size originals (often 50–200MB) are too big to seal + send P2P.
    @discardableResult
    func addVideo(url src: URL) async -> String {
        let ref = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(ref) else { return ref }
        try? FileManager.default.removeItem(at: dst)
        var ok = false
        if SettingsStore.shared.autoOptimize {
            ok = await Self.optimizeVideo(src, to: dst)
        }
        if !ok {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        cache[ref] = MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        return ref
    }

    /// Downscale so the longest side is at most `maxDimension` (keeps aspect ratio).
    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let m = max(image.size.width, image.size.height)
        guard m > maxDimension else { return image }
        let scale = maxDimension / m
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Transcode a video to a network-friendly 1080p H.264 MP4 (full HD, just
    /// re-encoded smaller than the camera original).
    static func optimizeVideo(_ src: URL, to dst: URL) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            return false
        }
        export.outputURL = dst
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed
    }

    /// Audio reuses `videoURL` as the file URL.
    @discardableResult
    func addAudio(url src: URL) -> String {
        let ref = "aud_\(UUID().uuidString)"
        if let dst = fileURL(ref) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            cache[ref] = MediaItem(id: ref, kind: .audio, image: nil, videoURL: dst)
        }
        return ref
    }

    /// Do we already hold the bytes for this ref?
    func has(_ ref: String) -> Bool {
        if cache[ref] != nil { return true }
        guard let url = fileURL(ref) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Raw bytes for a ref (to seal + send to a peer who's missing it).
    func rawBytes(_ ref: String) -> Data? {
        guard let url = fileURL(ref) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Store media bytes received from a peer, reconstructing the item for rendering.
    func store(_ ref: String, _ bytes: Data) {
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref) else { return }
        try? bytes.write(to: url)
        switch kind {
        case .image: cache[ref] = MediaItem(id: ref, kind: .image, image: UIImage(data: bytes), videoURL: nil)
        case .video: cache[ref] = MediaItem(id: ref, kind: .video, image: Self.poster(for: url), videoURL: url)
        case .audio: cache[ref] = MediaItem(id: ref, kind: .audio, image: nil, videoURL: url)
        }
    }

    func item(_ ref: String) -> MediaItem? {
        if let c = cache[ref] { return c }
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let item: MediaItem
        switch kind {
        case .image: item = MediaItem(id: ref, kind: .image, image: UIImage(contentsOfFile: url.path), videoURL: nil)
        case .video: item = MediaItem(id: ref, kind: .video, image: Self.poster(for: url), videoURL: url)
        case .audio: item = MediaItem(id: ref, kind: .audio, image: nil, videoURL: url)
        }
        cache[ref] = item
        return item
    }

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
