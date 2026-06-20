import SwiftUI
import AVFoundation
import UIKit

// A clean, modern story camera — tap the shutter for a photo, hold to record video —
// then a composer to add a song and a caption before sharing. No filters, no edit
// tools: just capture → caption → song → share, smooth and minimal.

// MARK: - Capture engine

@MainActor
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "kith.camera")

    @Published var isRecording = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var ready = false

    private var onPhoto: ((UIImage) -> Void)?
    private var onVideo: ((URL) -> Void)?

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
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
    }

    func flip() {
        position = (position == .back) ? .front : .back
        let pos = position
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configureInputs(position: pos)
            self.session.commitConfiguration()
        }
    }

    func capturePhoto(_ completion: @escaping (UIImage) -> Void) {
        onPhoto = completion
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func startRecording(_ completion: @escaping (URL) -> Void) {
        guard !movieOutput.isRecording else { return }
        onVideo = completion
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_\(UUID().uuidString).mov")
        // Mirror the front camera so it matches the preview.
        if let conn = movieOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (position == .front)
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = UIImage(data: data) else { return }
        Task { @MainActor in self.onPhoto?(img) }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.onVideo?(outputFileURL) }
    }
}

// MARK: - Live preview

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

// MARK: - Camera screen

struct StoryCameraView: View {
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraModel()
    @State private var pressing = false
    @State private var showLibrary = false
    @State private var draft: StoryDraft?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: cam.session).ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                    Button { cam.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3.weight(.semibold))
                            .foregroundStyle(.white).padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
                Spacer()
                bottomBar
            }
        }
        .statusBarHidden()
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
        .sheet(isPresented: $showLibrary) {
            MediaPicker { refs in
                if let ref = refs.first { draft = StoryDraft(mediaRef: ref) }
            }
        }
        .fullScreenCover(item: $draft) { d in
            StoryComposerView(draft: d) { ref, caption, track in
                onShare(ref, caption, track)
                dismiss()   // close the camera once shared
            }
        }
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
            Color.clear.frame(width: 52, height: 52)   // balance
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
    }

    private var shutter: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 5).frame(width: 82, height: 82)
            Circle().fill(cam.isRecording ? Color.red : Color.white)
                .frame(width: cam.isRecording ? 38 : 68, height: cam.isRecording ? 38 : 68)
                .animation(.spring(response: 0.3), value: cam.isRecording)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressing {
                        pressing = true
                        // Hold ≳0.35s → start video; a quick release before that is a photo.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if pressing && !cam.isRecording { cam.startRecording { url in finishVideo(url) } }
                        }
                    }
                }
                .onEnded { _ in
                    pressing = false
                    if cam.isRecording { cam.stopRecording() }
                    else { cam.capturePhoto { img in finishPhoto(img) } }
                }
        )
    }

    private func finishPhoto(_ img: UIImage) {
        draft = StoryDraft(mediaRef: MediaStore.shared.addImage(img))
    }
    private func finishVideo(_ url: URL) {
        Task { @MainActor in
            draft = StoryDraft(mediaRef: await MediaStore.shared.addVideo(url: url))
        }
    }
}

// MARK: - Draft + composer

struct StoryDraft: Identifiable {
    let id = UUID()
    let mediaRef: String
}

/// After capture: preview the shot, add a caption, pick a song, then share.
struct StoryComposerView: View {
    let draft: StoryDraft
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var track: TrackRefFfi?
    @State private var showSongs = false
    @State private var editingCaption = false
    @State private var captionStyleId = 0
    @State private var musicStartMs = 0.0
    @FocusState private var captionFocused: Bool

    private var style: StoryCaptionStyle { StoryCaptions.style(captionStyleId) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media.ignoresSafeArea()

            // Caption overlay (Instagram-style: tap to type, sits over the media)
            if !caption.isEmpty || editingCaption {
                VStack {
                    Spacer()
                    if captionFocused {
                        TextField("", text: $caption, axis: .vertical)
                            .focused($captionFocused)
                            .multilineTextAlignment(.center)
                            .font(style.font)
                            .foregroundStyle(style.textColor)
                            .tint(.white)
                            .padding(.horizontal, style.bgColor == nil ? 0 : 12)
                            .padding(.vertical, style.bgColor == nil ? 0 : 6)
                            .background { if let bg = style.bgColor { RoundedRectangle(cornerRadius: 8).fill(bg) } }
                            .padding(.horizontal, 24)
                    } else {
                        StyledCaption(text: caption, style: style)
                            .padding(.horizontal, 24)
                            .onTapGesture { editingCaption = true; captionFocused = true }
                    }
                    Spacer()
                }
            }

            VStack {
                topControls
                Spacer()
                if captionFocused { CaptionStyleRow(selectedId: $captionStyleId).padding(.bottom, 8) }
                if let track {
                    nowPlayingChip(track)
                    if track.durationMs > 16000 { musicSectionSlider(track) }
                }
                shareBar
            }
        }
        .statusBarHidden()
        .onTapGesture {
            if captionFocused { captionFocused = false }
            else if caption.isEmpty { editingCaption = true; captionFocused = true }
        }
        .sheet(isPresented: $showSongs) {
            SongPicker { t in track = t }
        }
    }

    @ViewBuilder private var media: some View {
        if let m = MediaStore.shared.item(draft.mediaRef) {
            if m.kind == .video, let url = m.videoURL {
                LoopingVideo(url: url)
            } else if let img = m.image {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
    }

    private var topControls: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.35), in: Circle())
            }
            Spacer()
            controlButton(caption.isEmpty ? "Aa" : "Aa", system: nil) {
                editingCaption = true; captionFocused = true
            }
            controlButton(nil, system: track == nil ? "music.note" : "music.note.list") {
                showSongs = true
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
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

    /// Pick which section of the song plays with the story (start offset).
    private func musicSectionSlider(_ t: TrackRefFfi) -> some View {
        let maxStart = Double(max(1, Int(t.durationMs) - 15_000))
        return HStack(spacing: 8) {
            Image(systemName: "scissors").font(.caption2).foregroundStyle(.white.opacity(0.85))
            Slider(value: $musicStartMs, in: 0...maxStart).tint(KithTheme.pink)
            Text(fmtTime(musicStartMs)).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 24).padding(.bottom, 6)
    }
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
            Button {
                onShare(draft.mediaRef, StoryCaptions.encode(caption, styleId: captionStyleId), trackForShare())
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text("Share to story").font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(KithTheme.brandHorizontal, in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }
}

/// A muted, looping video for the composer preview.
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.load(url)
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {}

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var looper: Any?
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        func load(_ url: URL) {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer(playerItem: item)
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            playerLayer.player = queue
            playerLayer.videoGravity = .resizeAspectFill
            queue.play()
        }
    }
}
