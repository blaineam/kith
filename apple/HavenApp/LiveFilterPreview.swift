import SwiftUI
import AVFoundation
import CoreImage
#if !os(macOS)
import MetalKit
import UIKit

// LIVE filter preview for the in-app cameras (post + story). Instead of an
// `AVCaptureVideoPreviewLayer` (which can only show the raw camera feed), the camera frames are
// tapped via an `AVCaptureVideoDataOutput`, pushed through the SAME `FilterEngine.apply(_:to:)`
// pipeline used after capture, and rendered to an `MTKView` with a `CIContext(mtlDevice:)`. The
// user swipes a `FilterStrip` and sees the look applied to the *live* feed before they shoot.
//
// Capture still happens through the existing photo/movie outputs (unfiltered), and the chosen
// live filter is carried forward as the default in the post review / story composer, which bake
// it into the bytes on "Use"/"Share". So the live view is a faithful preview; the on-disk media
// is filtered exactly once, by the existing code paths.
//
// macOS has no camera yet (placeholder), so this whole file is iOS-only.

// MARK: - Frame tap

/// Receives camera sample buffers (off the main thread), keeps the latest frame as a `CIImage`
/// for the Metal view to render, and periodically emits a small thumbnail for the filter strip
/// swatches. Orientation + front-camera mirroring are handled on the capture *connection* by the
/// owner, so the `CIImage` here is already upright and correctly mirrored.
final class LiveFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var _latest: CIImage?
    private var frameCount = 0
    /// Called on the main queue ~once a second with a downscaled still for the `FilterStrip`.
    var onThumbnail: ((PlatformImage) -> Void)?

    /// A lightweight CPU context just for the (small, infrequent) thumbnail stills.
    private static let thumbContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The most recent live frame, ready to filter + render. Thread-safe.
    var latest: CIImage? { lock.lock(); defer { lock.unlock() }; return _latest }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        lock.lock(); _latest = image; lock.unlock()

        // Refresh the filter-strip thumbnail a few times a second (every ~8 frames at 30fps) so the
        // swatches feel close to the live feed, without paying to render 11 filtered thumbnails on
        // every single frame.
        frameCount += 1
        guard frameCount % 8 == 0, let onThumbnail else { return }
        let target: CGFloat = 160
        let scale = target / max(image.extent.width, image.extent.height, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = Self.thumbContext.createCGImage(small, from: small.extent) else { return }
        let thumb = PlatformImage(cgImage: cg, scale: 1, orientation: .up)
        DispatchQueue.main.async { onThumbnail(thumb) }
    }
}

// MARK: - Metal-backed filtered view

/// Renders the latest live frame from a `LiveFrameTap`, run through `FilterEngine`, aspect-filling
/// the view (matching the old `.resizeAspectFill` preview). `.original` is a straight passthrough.
final class MetalCameraPreview: MTKView {
    /// The look to apply to every frame. Set instantly when the user taps a swatch.
    var filter: HavenFilter = .original
    /// How to orient each native (landscape) camera buffer so it displays upright (and mirrored
    /// for the selfie). Applied here in the render — `videoRotationAngle`/`isVideoMirrored` on a
    /// **data-output** connection do NOT reliably rotate the delivered buffers (only the file
    /// outputs do), which is why earlier fixes left the preview sideways. `.oriented()` is
    /// deterministic. Default `.right` = back camera, portrait.
    var orientation: CGImagePropertyOrientation = .right

    private let tap: LiveFrameTap
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var link: CADisplayLink?

    init(tap: LiveFrameTap, device: MTLDevice?) {
        self.tap = tap
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init(frame: .zero, device: device)
        framebufferOnly = false               // CIContext renders into the drawable texture
        colorPixelFormat = .bgra8Unorm
        isOpaque = true
        backgroundColor = .black
        autoResizeDrawable = true
        contentMode = .scaleAspectFill
        // We drive drawing from a display link (a new frame is ready ~every vsync), not the
        // built-in timer, so the view only renders while it's on screen.
        isPaused = true
        enableSetNeedsDisplay = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startLink() } else { stopLink() }
    }

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func stopLink() { link?.invalidate(); link = nil }
    @objc private func tick() { draw() }

    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable,
              let commandQueue, let ciContext,
              let buffer = commandQueue.makeCommandBuffer(),
              let input = tap.latest else { return }

        let filtered = (filter == .original) ? input : FilterEngine.apply(filter.spec, to: input)
        // Orient the native landscape buffer upright (+ mirror for the selfie). `.oriented()`
        // normalizes the extent so the aspect-fill math below still holds.
        let look = filtered.oriented(orientation)

        // Aspect-fill the frame into the drawable: scale to cover, then center.
        let dst = CGRect(origin: .zero, size: drawableSize)
        let ext = look.extent
        guard ext.width > 0, ext.height > 0, dst.width > 0, dst.height > 0 else { return }
        let scale = max(dst.width / ext.width, dst.height / ext.height)
        let tx = (dst.width - ext.width * scale) / 2 - ext.minX * scale
        let ty = (dst.height - ext.height * scale) / 2 - ext.minY * scale
        let image = look.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty)))

        ciContext.render(image, to: drawable.texture, commandBuffer: buffer,
                         bounds: dst, colorSpace: colorSpace)
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view exposing a live, filtered camera preview. The owner supplies the session's
/// `LiveFrameTap` (which it has already wired to an `AVCaptureVideoDataOutput`), the current
/// `filter`, and an optional thumbnail sink for the `FilterStrip`.
struct FilteredCameraPreview: UIViewRepresentable {
    let tap: LiveFrameTap
    var filter: HavenFilter
    /// How to orient the preview (upright + selfie mirror) — see `havenCameraOrientation`.
    var orientation: CGImagePropertyOrientation = .right
    var onThumbnail: ((PlatformImage) -> Void)? = nil

    func makeUIView(context: Context) -> MetalCameraPreview {
        let view = MetalCameraPreview(tap: tap, device: MTLCreateSystemDefaultDevice())
        view.filter = filter
        view.orientation = orientation
        tap.onThumbnail = onThumbnail
        return view
    }

    func updateUIView(_ view: MetalCameraPreview, context: Context) {
        view.filter = filter
        view.orientation = orientation
        tap.onThumbnail = onThumbnail
    }
}

// MARK: - Capture-connection helpers (shared by both cameras)

extension AVCaptureVideoDataOutput {
    /// Configure this data output for a live preview: BGRA frames (cheap to render in Metal),
    /// drop late frames, deliver to `tap` on `queue`.
    func wireLivePreview(tap: LiveFrameTap, queue: DispatchQueue) {
        alwaysDiscardsLateVideoFrames = true
        videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        setSampleBufferDelegate(tap, queue: queue)
    }
}

extension AVCaptureConnection {
    /// Orient + mirror this preview connection. `angle` is the `videoRotationAngle` (90 = portrait
    /// upright); front-facing previews are mirrored to match what the user expects to see.
    func applyPreviewOrientation(angle: CGFloat, mirroredFront: Bool) {
        if isVideoRotationAngleSupported(angle) { videoRotationAngle = angle }
        if isVideoMirroringSupported {
            automaticallyAdjustsVideoMirroring = false
            isVideoMirrored = mirroredFront
        }
    }
}

/// The `CGImagePropertyOrientation` that makes a **native (landscape) camera buffer** display
/// upright for the current device orientation + camera — used by the Metal preview, since
/// `videoRotationAngle` on a data-output connection doesn't reliably rotate delivered buffers.
/// Portrait: back = `.right`, front (mirrored selfie) = `.leftMirrored` — the standard mapping.
func havenCameraOrientation(position: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
    let front = position == .front
    switch UIDevice.current.orientation {
    case .portraitUpsideDown: return front ? .rightMirrored : .left
    case .landscapeLeft:      return front ? .downMirrored : .up
    case .landscapeRight:     return front ? .upMirrored : .down
    default:                  return front ? .leftMirrored : .right   // portrait + face up/down/unknown
    }
}

/// `videoRotationAngle` for the current device orientation (defaults to portrait/90).
func havenPreviewRotationAngle() -> CGFloat {
    switch UIDevice.current.orientation {
    case .landscapeLeft: return 0
    case .portraitUpsideDown: return 270
    case .landscapeRight: return 180
    default: return 90   // portrait (and face up/down/unknown)
    }
}
#endif
