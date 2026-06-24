import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A simple, intuitive in-app camera: tap the shutter for a photo, hold it to record
/// video, tap to flip. Captures stay on-device (sandbox), registered in `MediaStore`
/// and only ever sent after being sealed E2E. (AVCaptureSession needs a real device.)
///
/// After a capture, a lightweight review sheet shows the shot with a live `FilterStrip` so the
/// user can pick a `HavenFilter` and tap "Use" — the chosen look is baked into the media before
/// it's handed back via `onCaptured`. Default `.original` keeps the prior behavior.
struct CameraView: View {
    var onCaptured: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reviewRefs: [String]?
    // Live filter: applied to the camera feed in real time and carried into the review sheet as
    // the default. `liveThumb` is a downscaled still off the live feed for the swatches.
    @State private var liveFilter: HavenFilter = .original
    @State private var liveThumb: PlatformImage?

    var body: some View {
        ZStack {
            CameraCaptureRepresentable(filter: $liveFilter, onThumbnail: { liveThumb = $0 }) { refs in
                reviewRefs = refs
            }
            .ignoresSafeArea()

            // Live filter strip, floated above the (UIKit) shutter so swatches don't cover it.
            #if !os(macOS)
            if let liveThumb {
                VStack {
                    Spacer()
                    FilterStrip(thumbnail: liveThumb, selection: $liveFilter)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 10)
                }
                .padding(.bottom, 118)
                .allowsHitTesting(true)
            }
            #endif
        }
        .havenFullScreenCover(item: Binding(get: { reviewRefs.map { CaptureBatch(refs: $0) } },
                                       set: { reviewRefs = $0?.refs })) { batch in
            CaptureReviewView(refs: batch.refs, initialFilter: liveFilter) { finalRefs in
                reviewRefs = nil
                // Camera captures are media you made in-app → Haven ▸ Shared (when Save to
                // Photos is on). Save the FILTERED result the user actually chose.
                for ref in finalRefs {
                    if let item = MediaStore.shared.item(ref) {
                        PhotoSaver.saveIfEnabled(item, to: .shared, circleId: FeedStore.shared.activeCircleId)
                    }
                }
                onCaptured(finalRefs)
                dismiss()
            } onRetake: {
                reviewRefs = nil
            }
        }
    }
}

/// Identifiable wrapper so a `[String]` batch can drive a `fullScreenCover(item:)`. The id is
/// DERIVED from the refs (not a fresh UUID): the cover's `item:` binding is recomputed on every
/// view update, and a new UUID each time made SwiftUI think the item changed — dismissing and
/// re-presenting the review sheet in a loop (the "keeps opening and closing" flicker).
private struct CaptureBatch: Identifiable {
    var id: String { refs.joined(separator: "|") }
    let refs: [String]
}

/// The raw UIKit capture controller. Hands fresh capture refs up to the SwiftUI review layer
/// instead of finishing immediately.
#if !os(macOS)
struct CameraCaptureRepresentable: UIViewControllerRepresentable {
    @Binding var filter: HavenFilter
    var onThumbnail: ((PlatformImage) -> Void)? = nil
    var onCaptured: ([String]) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCaptured = onCaptured
        vc.onThumbnail = onThumbnail
        vc.onFilterChanged = { [b = $filter] in b.wrappedValue = $0 }
        vc.liveFilter = filter
        return vc
    }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {
        vc.onFilterChanged = { [b = $filter] in b.wrappedValue = $0 }
        if vc.liveFilter != filter { vc.liveFilter = filter }
    }
}
#endif

#if os(macOS)
/// Native macOS camera capture surface. Mirrors the iOS `CameraCaptureRepresentable` public
/// surface (`filter` binding, optional `onThumbnail`, `onCaptured: ([String]) -> Void`) so the
/// shared `CameraView` call site compiles unchanged.
///
/// Pragmatic v1: a live `AVCaptureVideoPreviewLayer` preview with a Capture (photo) button and a
/// Close button. On capture we take a still via `AVCapturePhotoOutput`, store it in `MediaStore`,
/// and hand the ref up via `onCaptured`. Live filtering (the iOS Metal preview) and video
/// recording are deferred; the captured still is filtered later in the shared `CaptureReviewView`.
struct CameraCaptureRepresentable: View {
    @Binding var filter: HavenFilter
    var onThumbnail: ((PlatformImage) -> Void)? = nil
    var onCaptured: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = MacCameraEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if engine.ready {
                MacCameraPreview(session: engine.session).ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Starting camera…")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 12)
                Spacer()
                Button { capture() } label: {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 5).frame(width: 78, height: 78)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!engine.ready || engine.capturing)
                .padding(.bottom, 28)
            }
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    private func capture() {
        engine.capturePhoto { img in
            guard let img else { return }
            Task { @MainActor in
                let ref = MediaStore.shared.addImage(img)
                onCaptured([ref])
            }
        }
    }
}

/// A minimal AVCaptureSession-backed engine for the native macOS photo-capture surface.
@MainActor
final class MacCameraEngine: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var ready = false
    @Published var capturing = false

    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "haven.maccamera.session")
    private var onPhoto: ((PlatformImage?) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        Task { @MainActor in self.ready = true }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
            // Release the camera device so the macOS camera indicator goes off.
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
    }

    func capturePhoto(_ completion: @escaping (PlatformImage?) -> Void) {
        guard !capturing else { return }
        capturing = true
        onPhoto = completion
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension MacCameraEngine: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img: PlatformImage? = photo.fileDataRepresentation().flatMap { PlatformImage(data: $0) }
        Task { @MainActor in
            self.capturing = false
            self.onPhoto?(img)
            self.onPhoto = nil
        }
    }
}

/// A layer-backed NSView showing an `AVCaptureVideoPreviewLayer` for the given session.
struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.attach(session: session)
        return v
    }
    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    final class PreviewNSView: NSView {
        private var preview: AVCaptureVideoPreviewLayer?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func attach(session: AVCaptureSession) {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer?.addSublayer(layer)
            preview = layer
        }
        override func layout() {
            super.layout()
            preview?.frame = bounds
        }
    }
}
#endif

/// Review a just-captured photo or video, pick a filter, then "Use" it. The filter is applied
/// via `MediaStore.applyFilter` (photos rewrite in place, videos export a filtered ref).
struct CaptureReviewView: View {
    let refs: [String]
    var onUse: ([String]) -> Void
    var onRetake: () -> Void

    @State private var filter: HavenFilter
    @State private var working = false

    /// `initialFilter` seeds the picker with whatever look was live on the camera, so the shot the
    /// user already framed with a filter keeps it by default.
    init(refs: [String], initialFilter: HavenFilter = .original,
         onUse: @escaping ([String]) -> Void, onRetake: @escaping () -> Void) {
        self.refs = refs
        self.onUse = onUse
        self.onRetake = onRetake
        _filter = State(initialValue: initialFilter)
    }

    /// Thumbnail for the strip: the first ref's still (photo or video poster).
    private var thumbnail: PlatformImage? { refs.first.flatMap { MediaStore.shared.item($0)?.image } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { onRetake() } label: {
                        Image(systemName: "chevron.left").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    Text("Retake or filter").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20).padding(.top, 8)

                // The preview (first ref). Photos preview the live look; videos play unfiltered
                // (the poster shows the look) and get the filter baked on export.
                if let ref = refs.first {
                    StoryMediaCanvas(mediaRef: ref, filter: filter)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                } else {
                    Spacer()
                }

                if let thumb = thumbnail {
                    FilterStrip(thumbnail: thumb, selection: $filter)
                }

                Button { use() } label: {
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(.white) }
                        else {
                            Text(refs.count > 1 ? "Use \(refs.count)" : "Use")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "checkmark")
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(HavenTheme.brandHorizontal, in: Capsule())
                }
                .disabled(working)
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 20)
            }
        }
        .havenStatusBarHidden()
    }

    private func use() {
        guard !working else { return }
        working = true
        let chosen = filter
        let input = refs
        Task { @MainActor in
            var out: [String] = []
            for ref in input { out.append(await MediaStore.shared.applyFilter(chosen, to: ref)) }
            working = false
            onUse(out)
        }
    }
}

#if !os(macOS)
final class CameraViewController: UIViewController,
    AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {

    var onCaptured: (([String]) -> Void)?
    var onThumbnail: ((PlatformImage) -> Void)?
    /// Fired when a swipe on the preview changes the filter, so the SwiftUI `FilterStrip` selection
    /// stays in sync.
    var onFilterChanged: ((HavenFilter) -> Void)?
    /// Live look applied to the Metal preview (and carried into the review sheet as the default).
    var liveFilter: HavenFilter = .original { didSet { metalPreview?.filter = liveFilter } }

    // Shutter press state (quick tap = photo, ≥0.35s hold = video).
    private var shutterHeld = false
    private var videoStarted = false

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    // Live filtered preview: frames tapped via a data output → FilterEngine → MTKView.
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let frameTap = LiveFrameTap()
    private let frameQueue = DispatchQueue(label: "haven.camera.frames")
    private var metalPreview: MetalCameraPreview?
    private var position: AVCaptureDevice.Position = .back
    private let shutter = UIButton(type: .system)
    private let ring = UIView()
    private let filterNameLabel = UILabel()
    private var filterNameHide: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { if granted { self.configure() } else { self.dismiss(animated: true) } }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        buildControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardownSession()
    }

    // Belt-and-suspenders: SwiftUI dismissing the fullScreenCover/sheet hosting this controller may
    // not always route through viewWillDisappear, so also tear the session down on dealloc. Both
    // paths are idempotent.
    deinit { teardownSession() }

    /// Fully stop the capture session and release the camera device so the iOS "in use" (green)
    /// indicator goes off — not just stopRunning, which keeps inputs/outputs (and the device) bound.
    private func teardownSession() {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        addCameraInput(position: position)
        if let mic = AVCaptureDevice.default(for: .audio),
           let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.wireLivePreview(tap: frameTap, queue: frameQueue)
            session.addOutput(videoDataOutput)
        }
        session.commitConfiguration()
        configurePreviewConnection()

        // The live filtered preview replaces the old AVCaptureVideoPreviewLayer.
        frameTap.onThumbnail = { [weak self] in self?.onThumbnail?($0) }
        let mtk = MetalCameraPreview(tap: frameTap, device: MTLCreateSystemDefaultDevice())
        mtk.filter = liveFilter
        mtk.frame = view.bounds
        mtk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(mtk, at: 0)
        metalPreview = mtk

        // Keep the preview upright as the device rotates (the old preview layer did this for us).
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)

        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    /// Orient + mirror the data-output (preview) connection AND the still/movie capture connections
    /// so the Metal preview matches reality and captured media isn't sideways. The front camera is
    /// mirrored so the selfie matches the (mirrored) live preview.
    private func configurePreviewConnection() {
        let angle = havenPreviewRotationAngle()
        let mirrorFront = position == .front
        videoDataOutput.connection(with: .video)?.applyPreviewOrientation(angle: angle, mirroredFront: mirrorFront)
        photoOutput.connection(with: .video)?.applyPreviewOrientation(angle: angle, mirroredFront: mirrorFront)
        movieOutput.connection(with: .video)?.applyPreviewOrientation(angle: angle, mirroredFront: mirrorFront)
    }

    @objc private func orientationChanged() {
        frameQueue.async { [weak self] in self?.configurePreviewConnection() }
    }

    private func addCameraInput(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.inputs.filter { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }
            .forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input) }
    }

    private func buildControls() {
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 4
        ring.layer.cornerRadius = 39
        ring.isUserInteractionEnabled = false
        view.addSubview(ring)

        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 30
        // Press model (mirrors the story camera): a quick tap = photo, a held press (≥0.35s) =
        // video. Driven by touch-down/up rather than a tap-vs-longpress recognizer pair, which
        // contended and occasionally produced a 0-second clip.
        shutter.addTarget(self, action: #selector(shutterDown), for: .touchDown)
        shutter.addTarget(self, action: #selector(shutterUp),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(shutter)

        let flip = button(symbol: "arrow.triangle.2.circlepath.camera", action: #selector(flip))
        let close = button(symbol: "xmark", action: #selector(closeTapped))
        view.addSubview(flip); view.addSubview(close)

        // Swipe left/right anywhere on the preview to flip through filters (full-frame-rate, unlike
        // the thumbnail strip). The strip stays as a tappable menu and follows along.
        let swipeL = UISwipeGestureRecognizer(target: self, action: #selector(swipeFilterLeft))
        swipeL.direction = .left
        let swipeR = UISwipeGestureRecognizer(target: self, action: #selector(swipeFilterRight))
        swipeR.direction = .right
        view.addGestureRecognizer(swipeL); view.addGestureRecognizer(swipeR)

        filterNameLabel.translatesAutoresizingMaskIntoConstraints = false
        filterNameLabel.textColor = .white
        filterNameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        filterNameLabel.textAlignment = .center
        filterNameLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        filterNameLabel.layer.cornerRadius = 14
        filterNameLabel.layer.masksToBounds = true
        filterNameLabel.alpha = 0
        filterNameLabel.isUserInteractionEnabled = false
        view.addSubview(filterNameLabel)
        NSLayoutConstraint.activate([
            filterNameLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            filterNameLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 70),
            filterNameLabel.heightAnchor.constraint(equalToConstant: 28),
            filterNameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutter.widthAnchor.constraint(equalToConstant: 60),
            shutter.heightAnchor.constraint(equalToConstant: 60),
            ring.centerXAnchor.constraint(equalTo: shutter.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 78),
            ring.heightAnchor.constraint(equalToConstant: 78),
            flip.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            flip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
        ])
    }

    private func button(symbol: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setImage(PlatformImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        b.layer.cornerRadius = 20
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func shutterDown() {
        shutterHeld = true
        videoStarted = false
        // Only commit to video once the press has lasted ≥0.35s; a quick release before that is a
        // photo. Because video never starts on a quick tap, we can't produce a 0-second clip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.shutterHeld, !self.videoStarted else { return }
            self.videoStarted = true
            // Mirror the front camera so the recording matches the (mirrored) live preview.
            if let conn = self.movieOutput.connection(with: .video), conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (self.position == .front)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.ring.layer.borderColor = UIColor.systemPink.cgColor
        }
    }

    @objc private func shutterUp() {
        let wasHeld = shutterHeld
        shutterHeld = false
        ring.layer.borderColor = UIColor.white.cgColor
        if videoStarted {
            videoStarted = false
            if movieOutput.isRecording { movieOutput.stopRecording() }
        } else if wasHeld {
            // Released before the 0.35s video threshold → it's a photo.
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    @objc private func flip() {
        position = (position == .back) ? .front : .back
        session.beginConfiguration()
        addCameraInput(position: position)
        session.commitConfiguration()
        configurePreviewConnection()   // front camera mirrors the live preview
    }

    @objc private func swipeFilterLeft() { cycleFilter(to: liveFilter.next) }
    @objc private func swipeFilterRight() { cycleFilter(to: liveFilter.prev) }

    /// Apply a new live filter from a swipe: update the Metal preview, sync the SwiftUI strip, and
    /// flash the filter's name.
    private func cycleFilter(to filter: HavenFilter) {
        liveFilter = filter            // didSet updates the Metal preview
        onFilterChanged?(filter)       // keep the FilterStrip selection in sync
        filterNameLabel.text = "  \(filter.title)  "
        filterNameHide?.cancel()
        UIView.animate(withDuration: 0.15) { self.filterNameLabel.alpha = 1 }
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.filterNameLabel.alpha = 0 }
        }
        filterNameHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: hide)
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = PlatformImage(data: data) else { return }
        Task { @MainActor in
            let ref = MediaStore.shared.addImage(img)
            finish([ref])
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            let ref = await MediaStore.shared.addVideo(url: url)
            finish([ref])
        }
    }

    @MainActor private func finish(_ refs: [String]) {
        // Hand the fresh capture up to the SwiftUI review layer (filter pick happens there). The
        // controller stays alive behind the review cover so "Retake" returns straight here.
        // Save-to-Photos is deferred to after filtering (see CameraView.onCaptured callers).
        onCaptured?(refs)
    }
}
#endif
