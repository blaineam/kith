import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(iOS)
import MediaPlayer
#endif

#if !os(macOS)
/// Locks the app to portrait while a view is on screen (the story camera/composer must never
/// rotate), restoring free rotation when it leaves.
struct PortraitLock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                HavenAppDelegate.orientationLock = .portrait
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
                UIViewController.attemptRotationToDeviceOrientationCompat()
            }
            .onDisappear { HavenAppDelegate.orientationLock = .all }
    }
}
#else
/// macOS has no orientation lock — there's no rotation to constrain, so this is a no-op.
struct PortraitLock: ViewModifier {
    func body(content: Content) -> some View { content }
}
#endif

extension View {
    /// Lock this screen to portrait (no rotation).
    func portraitLocked() -> some View { modifier(PortraitLock()) }
}

#if !os(macOS)
extension UIViewController {
    static func attemptRotationToDeviceOrientationCompat() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
#endif

// A clean, modern story camera — tap the shutter for a photo, hold to record video —
// then a composer to add a song and a caption before sharing. No filters, no edit
// tools: just capture → caption → song → share, smooth and minimal.

// MARK: - Capture engine

#if !os(macOS)
@MainActor
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "haven.camera")

    @Published var isRecording = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var ready = false
    /// Seconds elapsed in the current recording (drives the capture progress bar + the cap).
    @Published var recordingSeconds = 0.0
    /// Current zoom as a "× lens" factor relative to the wide camera (0.5 = ultra-wide).
    @Published var zoom = 1.0
    /// The lens presets available on this device's back camera (e.g. [0.5, 1, 2]).
    @Published var lensPresets: [Double] = [1, 2]

    private var device: AVCaptureDevice?
    private var usingUltraWide = false
    private var onPhoto: ((PlatformImage) -> Void)?
    private var onVideo: ((URL) -> Void)?
    private var recordTimer: Timer?
    /// When the current clip hits this many seconds, recording auto-stops (the 90s total cap).
    private var capSeconds = StoryCaptureModel.maxTotal

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.configureInputs(position: .back)
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            Task { @MainActor in self.ready = true }
        }
    }

    func stop() {
        queue.async { [weak self] in
            if self?.session.isRunning == true { self?.session.stopRunning() }
        }
    }

    private func configureInputs(position: AVCaptureDevice.Position) {
        for input in session.inputs { session.removeInput(input) }
        // Pick the lens: the ultra-wide (0.5×) when selected and available, else the wide camera.
        let type: AVCaptureDevice.DeviceType = (position == .back && usingUltraWide && hasUltraWide(position))
            ? .builtInUltraWideCamera : .builtInWideAngleCamera
        let cam = AVCaptureDevice.default(type, for: .video, position: position)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        if let cam, let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            device = cam
            try? cam.lockForConfiguration()
            cam.videoZoomFactor = 1.0
            cam.unlockForConfiguration()
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        Task { @MainActor in self.refreshLensPresets(position: position) }
    }

    private func hasUltraWide(_ position: AVCaptureDevice.Position) -> Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) != nil
    }

    /// The lens-button presets for the current camera: 0.5× if an ultra-wide exists, then 1×/2×
    /// (and 3× when the optics allow). The front camera has no lenses.
    @MainActor private func refreshLensPresets(position: AVCaptureDevice.Position) {
        guard position == .back else { lensPresets = []; zoom = 1.0; return }
        var presets: [Double] = []
        if hasUltraWide(position) { presets.append(0.5) }
        presets.append(1)
        let maxZ = device?.maxAvailableVideoZoomFactor ?? 1
        if maxZ >= 2 { presets.append(2) }
        if maxZ >= 3 { presets.append(3) }
        lensPresets = presets
        zoom = usingUltraWide ? 0.5 : 1.0
    }

    /// Pinch / lens-button zoom. `factor` is the "× lens" value (0.5 = ultra-wide, 1 = wide, …).
    func setZoom(_ factor: Double) {
        let pos = position
        queue.async { [weak self] in
            guard let self else { return }
            let wantUltra = (factor < 1.0) && self.hasUltraWide(pos)
            if wantUltra != self.usingUltraWide {
                // Crossing the 0.5×/1× boundary swaps the physical lens.
                self.usingUltraWide = wantUltra
                self.session.beginConfiguration()
                self.configureInputs(position: pos)
                self.session.commitConfiguration()
            }
            guard let dev = self.device else { return }
            // On the wide lens, digital zoom = factor; on ultra-wide, 0.5×→1× maps to 1.0→… .
            let base = self.usingUltraWide ? max(factor / 0.5, 1.0) : factor
            let clamped = max(dev.minAvailableVideoZoomFactor, min(base, min(dev.maxAvailableVideoZoomFactor, 8)))
            try? dev.lockForConfiguration()
            dev.videoZoomFactor = clamped
            dev.unlockForConfiguration()
            Task { @MainActor in self.zoom = factor }
        }
    }

    func flip() {
        position = (position == .back) ? .front : .back
        let pos = position
        usingUltraWide = false   // start each camera at 1× wide
        zoom = 1.0
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configureInputs(position: pos)
            self.session.commitConfiguration()
        }
    }

    func capturePhoto(_ completion: @escaping (PlatformImage) -> Void) {
        onPhoto = completion
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Start recording a clip. `maxSeconds` caps THIS clip (the remaining room under the 90s
    /// story limit); recording auto-stops when it's reached.
    func startRecording(maxSeconds: Double = StoryCaptureModel.maxTotal, _ completion: @escaping (URL) -> Void) {
        guard !movieOutput.isRecording, maxSeconds > 0.3 else { return }
        onVideo = completion
        capSeconds = maxSeconds
        recordingSeconds = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_\(UUID().uuidString).mov")
        // Mirror the front camera so it matches the preview.
        if let conn = movieOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (position == .front)
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 0.1
            if self.recordingSeconds >= self.capSeconds { self.stopRecording() }
        }
    }

    func stopRecording() {
        recordTimer?.invalidate(); recordTimer = nil
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = PlatformImage(data: data) else { return }
        Task { @MainActor in self.onPhoto?(img) }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.onVideo?(outputFileURL) }
    }
}
#else
/// macOS placeholder capture engine — live camera capture is Phase-2 native work. Exposes the
/// same published members the capture UI reads, as inert defaults, so call sites compile.
@MainActor
final class CameraModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var ready = false
    @Published var recordingSeconds = 0.0
    @Published var zoom = 1.0
    @Published var lensPresets: [Double] = [1, 2]

    func start() {}
    func stop() {}
    func setZoom(_ factor: Double) {}
    func flip() {}
    func capturePhoto(_ completion: @escaping (PlatformImage) -> Void) {}
    func startRecording(maxSeconds: Double = StoryCaptureModel.maxTotal, _ completion: @escaping (URL) -> Void) {}
    func stopRecording() {}
}
#endif

// MARK: - Live preview

#if !os(macOS)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#else
/// macOS placeholder for the live camera preview.
struct CameraPreview: View {
    let session: AVCaptureSession
    var body: some View { CameraUnavailablePlaceholder() }
}
#endif

/// Shared placeholder shown wherever live camera capture isn't yet available on macOS.
private struct CameraUnavailablePlaceholder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.85))
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.7))
                Text("Not available on Mac yet").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - Multi-clip capture model

/// Accumulates the video clips captured for one story session. Each clip is a separate story
/// (split into 15s chunks at share); the whole session is capped at 90s combined.
@MainActor
final class StoryCaptureModel: ObservableObject {
    static let maxTotal = 90.0   // 1.5 min combined
    static let chunk = 15.0      // each story chunk

    struct Segment: Identifiable { let id = UUID(); let ref: String; let duration: Double; let thumb: PlatformImage? }
    @Published var segments: [Segment] = []

    var total: Double { segments.reduce(0) { $0 + $1.duration } }
    var remaining: Double { max(0, Self.maxTotal - total) }
    var isFull: Bool { remaining < 0.5 }

    func add(ref: String, duration: Double, thumb: PlatformImage?) {
        segments.append(Segment(ref: ref, duration: min(max(duration, 0.1), Self.maxTotal), thumb: thumb))
    }
    func remove(_ id: UUID) { segments.removeAll { $0.id == id } }
    func clear() { segments.removeAll() }
}

// MARK: - Camera screen

#if !os(macOS)
struct StoryCameraView: View {
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    /// Hides the dual-camera (front+back PiP) entry point — its multi-cam preview renders black on
    /// device. Flip to true once the dual preview is properly wired.
    private static let dualCameraEnabled = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraModel()
    @StateObject private var dual = DualCameraRecorder()
    @StateObject private var capture = StoryCaptureModel()
    @State private var pressing = false
    @State private var showLibrary = false
    @State private var showReview = false
    @State private var draft: StoryDraft?
    @State private var dualMode = false
    @State private var pipCorner: PiPCorner = .bottomRight
    @State private var pinchBaseZoom = 1.0     // zoom at the start of a pinch
    @State private var recordStartZoom = 1.0   // zoom when a hold-to-record drag began

    private let minZoom = 0.5, maxZoom = 8.0
    private var isRec: Bool { dualMode ? dual.isRecording : cam.isRecording }
    private var recSecs: Double { dualMode ? dual.recordingSeconds : cam.recordingSeconds }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if dualMode {
                DualCameraPreview(recorder: dual, corner: pipCorner).ignoresSafeArea()
            } else {
                CameraPreview(session: cam.session).ignoresSafeArea()
                    // Pinch anywhere on the preview to zoom.
                    .gesture(MagnificationGesture()
                        .onChanged { v in cam.setZoom(min(maxZoom, max(minZoom, pinchBaseZoom * v))) }
                        .onEnded { _ in pinchBaseZoom = cam.zoom })
            }

            VStack {
                captureProgress   // segmented bars (story-viewer style) + live recording fill
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                    if capture.isFull {
                        Text("Max length").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        // Dual-camera (front + back PiP) toggle is DISABLED: the multi-cam preview
                        // renders black on device (the two preview connections aren't wired) and the
                        // feature added little. The recorder code stays for a future proper rebuild;
                        // the entry point is hidden so the normal camera always works.
                        if Self.dualCameraEnabled && DualCameraRecorder.isSupported {
                            Button { toggleDual() } label: {
                                Image(systemName: dualMode ? "person.2.fill" : "person.2")
                                    .font(.title3.weight(.semibold)).foregroundStyle(dualMode ? HavenTheme.pink : .white)
                                    .padding(10).background(.black.opacity(0.35), in: Circle())
                            }
                        }
                        if !dualMode {
                            Button { cam.flip() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3.weight(.semibold))
                                    .foregroundStyle(.white).padding(10).background(.black.opacity(0.35), in: Circle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4)
                if dualMode { cornerPicker.padding(.top, 8) }
                Spacer()
                if !dualMode { zoomControls }
                bottomBar
            }
        }
        .havenStatusBarHidden()
        .portraitLocked()
        .onAppear { cam.start() }
        .onDisappear { cam.stop(); dual.stop() }
        .sheet(isPresented: $showLibrary) {
            MediaPicker { refs in
                if let ref = refs.first { draft = StoryDraft(mediaRef: ref) }
            }
        }
        .havenFullScreenCover(isPresented: $showReview) {
            StoryReviewView(capture: capture,
                            onCaptureMore: { showReview = false },
                            onNext: {
                                showReview = false
                                let refs = capture.segments.map(\.ref)
                                // Let the review cover finish dismissing before presenting the composer.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { draft = StoryDraft(refs: refs) }
                            })
        }
        .havenFullScreenCover(item: $draft) { d in
            StoryComposerView(draft: d) { ref, caption, track in
                onShare(ref, caption, track)
            } onDone: {
                dismiss()   // close the camera once everything's shared
            }
        }
    }

    /// Story-viewer-style segmented progress: one filled bar per captured clip (width ∝ its
    /// 15s share), plus the live recording filling the next bar, all within the 90s budget.
    private var captureProgress: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let slots = capture.segments.map { $0.duration } + (isRec ? [recSecs] : [])
            let totalW = geo.size.width
            HStack(spacing: spacing) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, dur in
                    Capsule().fill(.white)
                        .frame(width: max(4, totalW * CGFloat(dur / StoryCaptureModel.maxTotal)))
                }
                Capsule().fill(.white.opacity(0.25))   // remaining budget
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 3)
        }
        .frame(height: 3)
        .padding(.horizontal, 12).padding(.top, 8)
        .opacity(capture.segments.isEmpty && !cam.isRecording ? 0 : 1)
    }

    /// Zoom UI for the single camera: a photo zoom slider (when not recording) + lens buttons.
    /// During recording you zoom by swiping up/down on the shutter (see `shutter`).
    @ViewBuilder private var zoomControls: some View {
        if cam.position == .back {
            VStack(spacing: 10) {
                if !isRec {
                    HStack(spacing: 10) {
                        Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.white)
                        Slider(value: Binding(get: { cam.zoom }, set: { cam.setZoom($0) }), in: minZoom...maxZoom)
                            .tint(.white)
                        Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 44)
                }
                if !cam.lensPresets.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(cam.lensPresets, id: \.self) { p in
                            let on = abs(cam.zoom - p) < 0.06
                            Button { cam.setZoom(p) } label: {
                                Text(lensLabel(p)).font(.caption2.weight(.bold))
                                    .foregroundStyle(on ? .black : .white)
                                    .frame(width: on ? 42 : 36, height: on ? 42 : 36)
                                    .background(Circle().fill(on ? Color.white : Color.black.opacity(0.4)))
                            }
                        }
                    }
                    .animation(.snappy, value: cam.zoom)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func lensLabel(_ p: Double) -> String {
        p < 1 ? "0.5×" : "\(Int(p))×"
    }

    private var bottomBar: some View {
        HStack {
            Button { showLibrary = true } label: {
                Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            Spacer()
            shutter
            Spacer()
            // Review/Next: appears once at least one clip is captured.
            if !capture.segments.isEmpty {
                Button { showReview = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(HavenTheme.pink)
                        Text("\(capture.segments.count)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(.black)).offset(x: 4, y: -4)
                    }
                    .frame(width: 52, height: 52)
                }
            } else {
                Color.clear.frame(width: 52, height: 52)   // balance
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
    }

    private var shutter: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 5).frame(width: 82, height: 82)
            Circle().fill(isRec ? Color.red : Color.white)
                .frame(width: isRec ? 38 : 68, height: isRec ? 38 : 68)
                .animation(.spring(response: 0.3), value: isRec)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !pressing && !capture.isFull {
                        pressing = true
                        recordStartZoom = cam.zoom
                        // Hold ≳0.35s → start video; a quick release before that is a photo
                        // (single-camera only — dual-camera is hold-to-record video).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            guard pressing, !isRec else { return }
                            if dualMode { dual.corner = pipCorner; dual.startRecording(maxSeconds: capture.remaining) { url in finishVideo(url) } }
                            else { cam.startRecording(maxSeconds: capture.remaining) { url in finishVideo(url) } }
                        }
                    }
                    // Swipe up/down while hold-recording → zoom (single camera). Up = zoom in.
                    if isRec && !dualMode {
                        let span = maxZoom - minZoom
                        let target = recordStartZoom + (-v.translation.height / 260.0) * span
                        cam.setZoom(min(maxZoom, max(minZoom, target)))
                    }
                }
                .onEnded { _ in
                    pressing = false
                    if isRec { dualMode ? dual.stopRecording() : cam.stopRecording() }
                    else if !dualMode && !capture.isFull { cam.capturePhoto { img in finishPhoto(img) } }
                }
        )
    }

    /// Switch between single and dual (front+back PiP) capture, starting/stopping the sessions.
    private func toggleDual() {
        guard !isRec else { return }
        dualMode.toggle()
        if dualMode { cam.stop(); dual.start() } else { dual.stop(); cam.start() }
    }

    /// Pick which corner the front-facing PiP renders in (dual mode).
    private var cornerPicker: some View {
        HStack(spacing: 10) {
            ForEach(PiPCorner.allCases) { c in
                Button { pipCorner = c; dual.corner = c } label: {
                    Image(systemName: c.icon).font(.title3)
                        .foregroundStyle(pipCorner == c ? HavenTheme.pink : .white)
                        .frame(width: 40, height: 40).background(.black.opacity(0.35), in: Circle())
                }
            }
        }
    }

    private func finishPhoto(_ img: PlatformImage) {
        // A photo is a single-frame story → straight to the composer (no multi-clip stacking).
        draft = StoryDraft(mediaRef: MediaStore.shared.addImage(img))
    }
    private func finishVideo(_ url: URL) {
        // A captured clip becomes a pending segment; stay in the camera to add more (or review).
        Task { @MainActor in
            let secs = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0.1
            let ref = await MediaStore.shared.addVideo(url: url)
            let thumb = MediaStore.shared.item(ref)?.image
            capture.add(ref: ref, duration: secs.isFinite ? secs : 0.1, thumb: thumb)
            if capture.isFull { showReview = true }
        }
    }
}
#else
/// macOS placeholder for the story camera — live capture is Phase-2 native work. Keeps the same
/// initializer signature (`onShare`) so call sites compile unchanged.
struct StoryCameraView: View {
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraUnavailablePlaceholder().padding(40)
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 8)
                Spacer()
            }
        }
        .portraitLocked()
    }
}
#endif

// MARK: - Draft + composer

struct StoryDraft: Identifiable {
    let id = UUID()
    let refs: [String]                         // one (photo / single clip) or many (multi-clip)
    init(mediaRef: String) { refs = [mediaRef] }
    init(refs: [String]) { self.refs = refs.isEmpty ? [""] : refs }
    var mediaRef: String { refs.first ?? "" }  // the preview frame
}

/// After capture: preview the shot, add a caption, pick a song, then share. A caption + song
/// apply to every clip in a multi-clip story.
struct StoryComposerView: View {
    let draft: StoryDraft
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var track: TrackRefFfi?
    @State private var showSongs = false
    @State private var showFilters = false
    @State private var filter: HavenFilter = .original
    @State private var sharing = false
    @State private var editingCaption = false
    @State private var captionSpec = StoryCaptions.Spec()
    @State private var musicStartMs = 0.0
    @State private var songPreviewing = false
    @State private var kbHeight: CGFloat = 0   // live keyboard height (the editor ignores the safe area)
    // Accumulators so pinch/drag continue from the current framing each gesture.
    @State private var mediaBaseScale: CGFloat = 1
    @State private var mediaBaseOffX: CGFloat = 0
    @State private var mediaBaseOffY: CGFloat = 0
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media.ignoresSafeArea()

            // A full-screen layer: tap toggles caption editing; pinch/drag reframes the media
            // (only when not editing, so the gestures don't fight the keyboard/caption).
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture {
                        if editingCaption { captionFocused = false; editingCaption = false }
                        else { editingCaption = true }
                    }
                    .gesture(editingCaption ? nil : SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { v in captionSpec.mediaScale = min(max(1, mediaBaseScale * v), 4) }
                            .onEnded { _ in mediaBaseScale = captionSpec.mediaScale },
                        DragGesture()
                            .onChanged { v in
                                captionSpec.mediaOffX = mediaBaseOffX + v.translation.width / max(geo.size.width, 1)
                                captionSpec.mediaOffY = mediaBaseOffY + v.translation.height / max(geo.size.height, 1)
                            }
                            .onEnded { _ in mediaBaseOffX = captionSpec.mediaOffX; mediaBaseOffY = captionSpec.mediaOffY }
                    ))
            }

            // Caption overlay (Instagram-style: tap to type, sits over the media).
            // Centered, but lifted into the visible area above the keyboard while editing.
            if editingCaption {
                VStack {
                    Spacer()
                    TextField("", text: $caption, axis: .vertical)
                        .focused($captionFocused)
                        .multilineTextAlignment(.center)
                        .font(StoryCaptions.font(captionSpec))
                        .foregroundStyle(StoryCaptions.textColor(captionSpec))
                        // Show the glow/shadow/neon look live while typing (#88), not only after closing.
                        .modifier(CaptionStyleEffect(spec: captionSpec))
                        .tint(.white)
                        .padding(.horizontal, StoryCaptions.bgColor(captionSpec) == nil ? 0 : 12)
                        .padding(.vertical, StoryCaptions.bgColor(captionSpec) == nil ? 0 : 6)
                        .background { if let bg = StoryCaptions.bgColor(captionSpec) { RoundedRectangle(cornerRadius: 8).fill(bg) } }
                        .padding(.horizontal, 24)
                        .onAppear {
                            // Focus must be set *after* the field is in the hierarchy.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { captionFocused = true }
                        }
                    Spacer()
                }
                .offset(y: -kbHeight / 2)
                .animation(.easeOut(duration: 0.25), value: kbHeight)
            } else if !caption.isEmpty {
                // Draggable: position the caption anywhere; the spot travels with the story.
                GeometryReader { geo in
                    StyledCaption(text: caption, spec: captionSpec)
                        .padding(.horizontal, 12)
                        .position(x: captionSpec.x * geo.size.width, y: captionSpec.y * geo.size.height)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    captionSpec.x = min(max(0.12, v.location.x / geo.size.width), 0.88)
                                    captionSpec.y = min(max(0.10, v.location.y / geo.size.height), 0.90)
                                }
                        )
                        .onTapGesture { editingCaption = true }
                }
            }

            VStack {
                if !editingCaption { topControls } else { editingTopBar }
                Spacer()
                if let track {
                    nowPlayingChip(track)
                    if track.durationMs > 16000 && !editingCaption { musicSectionSlider(track) }
                }
                // Caption style controls sit as a bar right above the keyboard while editing.
                if editingCaption { captionStyleControls.padding(.bottom, 8) }
                if !editingCaption && showFilters { filterBar.padding(.bottom, 8) }
                if !editingCaption { shareBar }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // pin controls to the screen, never the media's size
            .padding(.bottom, editingCaption ? kbHeight : 0)   // lift the style bar to the keyboard edge
            // Opt out of SwiftUI's automatic keyboard avoidance — otherwise it stacks on top of
            // our manual kbHeight lift and shoves the controls to the top of the screen.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.easeOut(duration: 0.25), value: kbHeight)
        }
        .havenStatusBarHidden()
        .portraitLocked()
        .modifier(KeyboardHeightObserver(kbHeight: $kbHeight))
        .sheet(isPresented: $showSongs) {
            SongPicker { t in track = t }
        }
    }

    private var media: some View {
        StoryMediaCanvas(mediaRef: draft.mediaRef,
                         scale: captionSpec.mediaScale, offX: captionSpec.mediaOffX, offY: captionSpec.mediaOffY,
                         filter: filter)
    }

    /// While editing the caption, the top bar is just a Done button — the styling lives in the
    /// bar above the keyboard.
    private var editingTopBar: some View {
        HStack {
            Spacer()
            Button { captionFocused = false; editingCaption = false } label: {
                Text("Done").font(.headline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.black.opacity(0.4), in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var topControls: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.35), in: Circle())
            }
            Spacer()
            controlButton("Aa", system: nil) {
                editingCaption = true
            }
            controlButton(nil, system: "camera.filters") {
                withAnimation(HavenTheme.smooth) { showFilters.toggle() }
            }
            .overlay(alignment: .topTrailing) {
                if filter != .original {
                    Circle().fill(HavenTheme.pink).frame(width: 10, height: 10).offset(x: 2, y: -2)
                }
            }
            controlButton(nil, system: track == nil ? "music.note" : "music.note.list") {
                showSongs = true
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    /// Live filter chooser under the preview. Uses the preview frame (photo / video poster) as
    /// the thumbnail; the chosen look is baked into every shared ref at share time.
    @ViewBuilder private var filterBar: some View {
        if let thumb = MediaStore.shared.item(draft.mediaRef)?.image {
            FilterStrip(thumbnail: thumb, selection: $filter)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func controlButton(_ text: String?, system: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let text { Text(text).font(.headline.weight(.bold)) }
                else if let system { Image(systemName: system).font(.title3.weight(.semibold)) }
            }
            .foregroundStyle(.white).frame(width: 42, height: 42)
            .background(.black.opacity(0.35), in: Circle())
        }
    }

    /// Caption editing controls: tap-through typography, highlight toggle, color row.
    private var captionStyleControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { captionSpec.cycleFont() } label: {
                    Text("Aa").font(.headline.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.black.opacity(0.4), in: Circle())
                }
                // Cycle the caption style (plain → glow → shadow → neon → highlight), like the font.
                Button { captionSpec.cycleStyle() } label: {
                    VStack(spacing: 1) {
                        Image(systemName: captionSpec.style.icon).font(.subheadline)
                        Text(captionSpec.style.label).font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(.black.opacity(0.4), in: Circle())
                }
                // Size slider — the caption scale travels to viewers in the spec.
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller").font(.caption).foregroundStyle(.white)
                    Slider(value: $captionSpec.size, in: StoryCaptions.minSize...StoryCaptions.maxSize)
                        .tint(HavenTheme.pink)
                    Image(systemName: "textformat.size.larger").font(.body).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            CaptionColorRow(spec: $captionSpec)
        }
    }

    /// A clean HUD to scrub + preview which 15s of the song plays with the story.
    private func musicSectionSlider(_ t: TrackRefFfi) -> some View {
        let maxStart = Double(max(1, Int(t.durationMs) - 15_000))
        return HStack(spacing: 12) {
            Button { toggleSongPreview(t) } label: {
                Image(systemName: songPreviewing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("15s clip from \(fmtTime(musicStartMs))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                Slider(value: $musicStartMs, in: 0...maxStart) { editing in
                    if !editing && songPreviewing { seekPreview() }
                }
                .tint(HavenTheme.pink)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onChange(of: musicStartMs) { if songPreviewing { seekPreview() } }
        .onDisappear { stopSongPreview() }
    }

#if os(iOS)
    private func toggleSongPreview(_ t: TrackRefFfi) {
        let player = MPMusicPlayerController.applicationMusicPlayer
        if songPreviewing { stopSongPreview(); return }
        let ids = trackIds(t.catalogId)
        if let pid = ids.pid, let item = librarySong(pid) { player.setQueue(with: MPMediaItemCollection(items: [item])) }
        else if let store = ids.store { player.setQueue(with: [store]) }
        player.play()
        player.currentPlaybackTime = musicStartMs / 1000
        songPreviewing = true
    }
    private func stopSongPreview() {
        if songPreviewing { MPMusicPlayerController.applicationMusicPlayer.stop() }
        songPreviewing = false
    }
    private func seekPreview() {
        MPMusicPlayerController.applicationMusicPlayer.currentPlaybackTime = musicStartMs / 1000
    }
#else
    // MediaPlayer (MPMusicPlayerController) is unavailable on native macOS — no-op previews.
    private func toggleSongPreview(_ t: TrackRefFfi) {}
    private func stopSongPreview() { songPreviewing = false }
    private func seekPreview() {}
#endif
    private func fmtTime(_ ms: Double) -> String {
        let s = Int(ms / 1000); return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The track with the chosen section start baked in (artworkUrl = "start:<ms>").
    private func trackForShare() -> TrackRefFfi? {
        guard let t = track else { return nil }
        guard musicStartMs > 0 else { return t }
        return TrackRefFfi(catalogId: t.catalogId, title: t.title, artist: t.artist,
                           artworkUrl: "start:\(Int(musicStartMs))", durationMs: t.durationMs)
    }

    private func nowPlayingChip(_ t: TrackRefFfi) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").font(.caption)
            Text("\(t.title) · \(t.artist)").font(.caption.weight(.medium)).lineLimit(1)
            Button { track = nil } label: { Image(systemName: "xmark.circle.fill") }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.black.opacity(0.4), in: Capsule())
        .padding(.bottom, 12)
    }

    private var shareBar: some View {
        HStack {
            Spacer()
            Button { share() } label: {
                HStack(spacing: 8) {
                    if sharing {
                        ProgressView().tint(.white)
                    } else {
                        Text(draft.refs.count > 1 ? "Share \(draft.refs.count) stories" : "Share to story")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "arrow.right")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(HavenTheme.brandHorizontal, in: Capsule())
            }
            .disabled(sharing)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    /// Bake the chosen filter into every clip (photos rewrite in place, videos export a new
    /// filtered ref), then hand each off as its own story. `.original` is a no-op so existing
    /// capture behavior is unchanged.
    private func share() {
        guard !sharing else { return }
        sharing = true
        let body = StoryCaptions.encode(caption, captionSpec)
        let chosen = filter
        let track = trackForShare()
        let refs = draft.refs.filter { !$0.isEmpty }
        Task { @MainActor in
            for ref in refs {
                let outRef = await MediaStore.shared.applyFilter(chosen, to: ref)
                onShare(outRef, body, track)
            }
            sharing = false
            dismiss(); onDone()
        }
    }
}

/// Tracks the live keyboard height. On iOS/Catalyst it observes the system keyboard
/// notifications; on native macOS there is no software keyboard, so it's a no-op.
private struct KeyboardHeightObserver: ViewModifier {
    @Binding var kbHeight: CGFloat
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { kbHeight = f.height }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in kbHeight = 0 }
        #else
        content
        #endif
    }
}

/// Review captured story clips before sharing: swipe through each, trash any, capture more
/// (back to the camera), or continue to the composer.
struct StoryReviewView: View {
    @ObservedObject var capture: StoryCaptureModel
    var onCaptureMore: () -> Void
    var onNext: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !capture.segments.isEmpty {
                TabView(selection: $index) {
                    ForEach(Array(capture.segments.enumerated()), id: \.element.id) { i, seg in
                        StoryMediaCanvas(mediaRef: seg.ref).tag(i).ignoresSafeArea()
                    }
                }
                #if !os(macOS)
                // `.page` tabViewStyle (swipe between clips) is unavailable on native macOS.
                .havenPagedTabViewStyle(showsIndex: false)
                #endif
                .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { dismiss(); onCaptureMore() } label: {
                        Image(systemName: "chevron.left").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    Text("\(capture.segments.count) clip\(capture.segments.count == 1 ? "" : "s") · \(Int(capture.total))s / 90s")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Button(role: .destructive) { trashCurrent() } label: {
                        Image(systemName: "trash.fill").font(.title3).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.4), in: Circle())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
                Spacer()
                HStack {
                    Button { dismiss(); onCaptureMore() } label: {
                        Label("Capture more", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    .disabled(capture.isFull).opacity(capture.isFull ? 0.5 : 1)
                    Spacer()
                    Button { onNext() } label: {
                        HStack(spacing: 8) { Text("Next").font(.subheadline.weight(.semibold)); Image(systemName: "arrow.right") }
                            .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
                            .background(HavenTheme.brandHorizontal, in: Capsule())
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
        }
        .havenStatusBarHidden()
        .portraitLocked()
    }

    private func trashCurrent() {
        guard capture.segments.indices.contains(index) else { return }
        capture.remove(capture.segments[index].id)
        if capture.segments.isEmpty { dismiss(); onCaptureMore() }
        else { index = min(index, capture.segments.count - 1) }
    }
}

/// A muted, looping video for the composer preview.
#if !os(macOS)
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var fill: Bool = true   // false → fit (letterbox), e.g. show a landscape clip in full
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.load(url, fill: fill)
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {}

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var looper: Any?
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        func load(_ url: URL, fill: Bool) {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer(playerItem: item)
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            playerLayer.player = queue
            playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            queue.play()
        }
    }
}
#else
/// macOS placeholder for the looping-video preview — backed by AVPlayer wiring is Phase-2 work.
/// Keeps the same `url`/`fill` members so call sites compile unchanged.
struct LoopingVideo: View {
    let url: URL
    var fill: Bool = true
    var body: some View { CameraUnavailablePlaceholder() }
}
#endif

// `Image(platformImage:)` is provided centrally in Platform.swift.

/// Renders story media inside the standard 9:16 canvas: the media is shown in **full** (fit),
/// centered, over a **blurred fill of itself** — so landscape (or any off-ratio) photos and
/// videos sit cleanly within the frame instead of cropping or leaving dead bands.
struct StoryMediaCanvas: View {
    let mediaRef: String
    /// Author's framing: zoom + normalized translation (fraction of canvas).
    var scale: CGFloat = 1
    var offX: CGFloat = 0
    var offY: CGFloat = 0
    /// Live preview-only filter. The look is applied to the still here for instant feedback; it
    /// is baked into the actual media bytes at share time (videos preview unfiltered — the
    /// poster shows the look — and get the filter on export). Defaults to `.original` (no-op).
    var filter: HavenFilter = .original

    /// The (optionally filtered) preview still for this ref.
    private func preview(_ img: PlatformImage) -> PlatformImage {
        filter == .original ? img : FilterEngine.apply(filter, to: img)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black   // base so there's never a transparent gap
                if let m = MediaStore.shared.item(mediaRef) {
                    let still = m.image.map(preview)
                    // Blurred fill backdrop, sized to the WHOLE canvas (the still covers photo
                    // + video). Explicit frame is what makes it fill instead of collapsing to
                    // the fit-image's height.
                    if let img = still {
                        Image(platformImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: 28)
                            .overlay(Color.black.opacity(0.28))
                    }
                    // Foreground: the media aspect-FILLS the canvas by default (covers it, no bars),
                    // with the author's zoom/reposition layered on top — pinch/drag reframes from
                    // there. (Was scaledToFit, which left letterbox gaps the blurred backdrop showed
                    // through.)
                    Group {
                        if m.kind == .video, let url = m.videoURL {
                            // Video plays unfiltered in preview (the filter is baked on export);
                            // a still photo previews the live look immediately.
                            LoopingVideo(url: url, fill: true)
                        } else if let img = still {
                            Image(platformImage: img).resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .scaleEffect(scale)
                    .offset(x: offX * geo.size.width, y: offY * geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
