import SwiftUI
import AVFoundation
import CoreImage
import CoreLocation
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Photos

/// Save a post's media (photo or video) into the user's Photos library.
@MainActor
enum MediaSaver {
    static func save(_ ref: String) {
        guard let m = MediaStore.shared.item(ref) else { return }
        let imageURL = MediaStore.shared.storagePath(for: ref)
        let kind = m.kind
        let videoURL = m.videoURL
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                switch kind {
                case .video:
                    if let url = videoURL { PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                case .image:
                    if let url = imageURL { PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url) }
                case .audio:
                    break
                }
            } completionHandler: { _, _ in }
        }
    }
}

#if os(macOS)
/// Native macOS has no UIVideoEditorController; trim isn't offered (canTrim → false). This stub
/// just dismisses itself if ever presented.
struct VideoTrimmer: View {
    let path: String
    var onTrimmed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View { Color.clear.onAppear { dismiss() } }
}
#elseif targetEnvironment(macCatalyst)
/// Mac Catalyst has no UIVideoEditorController; trim isn't offered there (canTrim → false).
struct VideoTrimmer: UIViewControllerRepresentable {
    let path: String
    var onTrimmed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIViewController {
        DispatchQueue.main.async { dismiss() }
        return UIViewController()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
#else
/// The system video trimmer (UIVideoEditorController) wrapped for SwiftUI.
struct VideoTrimmer: UIViewControllerRepresentable {
    let path: String
    var onTrimmed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIVideoEditorController.canEditVideo(atPath: path) else {
            DispatchQueue.main.async { dismiss() }
            return UIViewController()
        }
        let vc = UIVideoEditorController()
        vc.videoPath = path
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIVideoEditorControllerDelegate {
        let parent: VideoTrimmer
        init(_ parent: VideoTrimmer) { self.parent = parent }
        func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath path: String) {
            parent.onTrimmed(URL(fileURLWithPath: path)); parent.dismiss()
        }
        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) { parent.dismiss() }
        func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: Error) { parent.dismiss() }
    }
}
#endif

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
    let image: PlatformImage?   // the photo, or a video's poster frame
    let videoURL: URL?
}

/// Persistent, content-ref'd media store. Refs encode the kind (img_/vid_/aud_) so a
/// recipient who receives the bytes can reconstruct the item. Files live under
/// Application Support/haven-media so they survive app restarts and updates.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()
    private var cache: [String: MediaItem] = [:]

    // MARK: - Captured location (opt-in)

    /// GPS coords extracted from a picked photo/video at import, kept on-device only. The raw
    /// metadata is stripped from the shared bytes; this coordinate is shared ONLY if the author
    /// flips the per-post "Show location" toggle (then it's reverse-geocoded into a `geo:` pin).
    private var locations: [String: CLLocationCoordinate2D] = [:]
    func setLocation(_ c: CLLocationCoordinate2D, for ref: String) { locations[ref] = c }
    func location(for ref: String) -> CLLocationCoordinate2D? { locations[ref] }
    /// Whether any of these refs carries a captured location (drives the compose toggle's visibility).
    func anyLocated(_ refs: [String]) -> Bool { refs.contains { locations[$0] != nil } }

    /// Pull a GPS coordinate out of raw image bytes (EXIF GPS dictionary), or nil if absent.
    static func gpsCoordinate(fromImageData data: Data) -> CLLocationCoordinate2D? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat,
                                      longitude: lonRef == "W" ? -lon : lon)
    }

    private var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func fileURL(_ ref: String) -> URL? {
        guard let kind = MediaKind(ref: ref) else { return nil }
        return dir.appendingPathComponent("\(ref).\(kind.ext)")
    }

    @discardableResult
    func addImage(_ image: PlatformImage) -> String {
        let ref = "img_\(UUID().uuidString)"
        // Optimize: downscale very large photos + compress, so they're light to send —
        // but keep it high-res (longest edge up to 2560, well above 1080p).
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
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
        if CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId) {
            ok = await Self.optimizeVideo(src, to: dst)   // re-encode also drops metadata
        }
        // Strip metadata (GPS/location, creation device, etc.) before it ever leaves the device —
        // a fast pass-through remux, no re-encode. Falls back to a raw copy only if that fails.
        if !ok {
            ok = await Self.stripVideoMetadata(src, to: dst)
        }
        if !ok {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        cache[ref] = MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        return ref
    }

    /// Remux a video to drop its metadata (location, device, timestamps) without re-encoding.
    static func stripVideoMetadata(_ src: URL, to dst: URL) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        export.outputURL = dst
        export.outputFileType = .mov
        export.metadata = []   // no location/maker metadata travels with shared media
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed
    }

    static let storySlideMax: Double = 15.0   // max seconds per story slide
    static let storyMaxSlides = 5             // a long video splits into at most this many

    /// Split a long video into up to 5 consecutive ≤15s segments for a story. Photos and
    /// short videos pass through unchanged (returns [ref]).
    func splitStoryVideo(_ ref: String) async -> [String] {
        guard let m = item(ref), m.kind == .video, let src = storagePath(for: ref) else { return [ref] }
        let asset = AVURLAsset(url: src)
        let dur = ((try? await asset.load(.duration))?.seconds) ?? 0
        if dur <= Self.storySlideMax { return [ref] }
        let count = min(Self.storyMaxSlides, Int(ceil(dur / Self.storySlideMax)))
        var refs: [String] = []
        for i in 0..<count {
            let start = Double(i) * Self.storySlideMax
            let len = min(Self.storySlideMax, dur - start)
            if len <= 0.5 { break }
            if let seg = await exportSegment(asset: asset, start: start, duration: len) { refs.append(seg) }
        }
        return refs.isEmpty ? [ref] : refs
    }

    private func exportSegment(asset: AVAsset, start: Double, duration: Double) async -> String? {
        let newRef = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(newRef),
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { return nil }
        export.outputURL = dst
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else { return nil }
        cache[newRef] = MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        return newRef
    }

    /// Produce a muted copy of a video (audio track stripped); returns a new ref.
    func muteVideo(_ ref: String) async -> String? {
        guard let src = storagePath(for: ref) else { return nil }
        let asset = AVURLAsset(url: src)
        let comp = AVMutableComposition()
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let dur = (try? await asset.load(.duration)) ?? .zero
        try? compV.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
        if let xf = try? await vTrack.load(.preferredTransform) { compV.preferredTransform = xf }
        let newRef = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(newRef),
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        export.outputURL = dst
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else { return nil }
        cache[newRef] = MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        return newRef
    }

    /// Adopt an externally-trimmed video file as a new ref.
    func importTrimmed(_ url: URL) -> String {
        let ref = "vid_\(UUID().uuidString)"
        if let dst = fileURL(ref) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: url, to: dst)
            cache[ref] = MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        }
        return ref
    }

    // MARK: - Filters

    /// Apply a `HavenFilter` to an existing media ref and return the ref of the filtered media
    /// to send. `.original` is a no-op (returns the same ref). For images the bytes are
    /// re-written in place under the same ref; for videos a new filtered ref is produced via a
    /// Core Image video composition export (the original ref is left untouched). All color math
    /// lives in `FilterEngine` — this only orchestrates storage. Returns the original ref on any
    /// failure so capture never breaks.
    @discardableResult
    func applyFilter(_ filter: HavenFilter, to ref: String) async -> String {
        guard filter != .original, let item = item(ref) else { return ref }
        switch item.kind {
        case .image:
            guard let img = item.image else { return ref }
            let filtered = FilterEngine.apply(filter, to: img)
            return replaceImage(ref: ref, with: filtered) ? ref : ref
        case .video:
            return await filteredVideo(ref, filter: filter) ?? ref
        case .audio:
            return ref
        }
    }

    /// Overwrite an image ref's bytes + cache with a new image (same ref). Returns whether it
    /// stuck.
    @discardableResult
    private func replaceImage(ref: String, with image: PlatformImage) -> Bool {
        guard MediaKind(ref: ref) == .image, let url = fileURL(ref) else { return false }
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        let img = optimize ? Self.downscale(image, maxDimension: 2560) : image
        let quality: CGFloat = optimize ? 0.88 : 0.95
        guard let data = img.jpegData(compressionQuality: quality) else { return false }
        do { try data.write(to: url) } catch { return false }
        cache[ref] = MediaItem(id: ref, kind: .image, image: img, videoURL: nil)
        return true
    }

    /// Export a new video ref with `filter` baked into every frame via
    /// `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`. Returns the new ref, or
    /// nil on failure (caller falls back to the unfiltered ref).
    private func filteredVideo(_ ref: String, filter: HavenFilter) async -> String? {
        guard let src = storagePath(for: ref) else { return nil }
        let spec = filter.spec
        let asset = AVURLAsset(url: src)
        // Per-frame CI pipeline reusing the exact same FilterEngine math as stills.
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            let output = FilterEngine.apply(spec, to: source).cropped(to: request.sourceImage.extent)
            request.finish(with: output, context: nil)
        }
        let newRef = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(newRef),
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            return nil
        }
        try? FileManager.default.removeItem(at: dst)
        export.outputURL = dst
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = composition
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
        cache[newRef] = MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        return newRef
    }

    /// Downscale so the longest side is at most `maxDimension` (keeps aspect ratio).
    /// Cross-platform via `PlatformImage.downscaled` (Platform.swift).
    static func downscale(_ image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        image.downscaled(maxDimension: maxDimension)
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
        case .image: cache[ref] = MediaItem(id: ref, kind: .image, image: PlatformImage(data: bytes), videoURL: nil)
        case .video: cache[ref] = MediaItem(id: ref, kind: .video, image: Self.poster(for: url), videoURL: url)
        case .audio: cache[ref] = MediaItem(id: ref, kind: .audio, image: nil, videoURL: url)
        }
    }

    /// Final on-disk path for a ref (sender reads chunks from here).
    func storagePath(for ref: String) -> URL? { fileURL(ref) }

    /// A fresh empty temp file for reassembling an incoming chunked transfer.
    func makeTempFile() -> URL {
        let u = dir.appendingPathComponent("incoming_\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: u.path, contents: nil)
        return u
    }

    /// Move a fully-reassembled temp file into place under `ref` and cache the item.
    func adopt(_ ref: String, from temp: URL) {
        guard let kind = MediaKind(ref: ref), let dst = fileURL(ref) else { return }
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: temp, to: dst) } catch { return }
        switch kind {
        case .image: cache[ref] = MediaItem(id: ref, kind: .image, image: PlatformImage(contentsOfFile: dst.path), videoURL: nil)
        case .video: cache[ref] = MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst)
        case .audio: cache[ref] = MediaItem(id: ref, kind: .audio, image: nil, videoURL: dst)
        }
    }

    func item(_ ref: String) -> MediaItem? {
        if let c = cache[ref] { return c }
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let item: MediaItem
        switch kind {
        case .image: item = MediaItem(id: ref, kind: .image, image: PlatformImage(contentsOfFile: url.path), videoURL: nil)
        case .video: item = MediaItem(id: ref, kind: .video, image: Self.poster(for: url), videoURL: url)
        case .audio: item = MediaItem(id: ref, kind: .audio, image: nil, videoURL: url)
        }
        cache[ref] = item
        return item
    }

    /// Can this video be trimmed by the system editor? (Not on Mac Catalyst.)
    func canTrim(_ ref: String) -> Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return false
        #else
        guard let url = storagePath(for: ref) else { return false }
        return UIVideoEditorController.canEditVideo(atPath: url.path)
        #endif
    }

    /// Extract a poster frame so videos show something before playback.
    static func poster(for url: URL) -> PlatformImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        else { return nil }
        return PlatformImage(cgImage: cg)
    }
}
