import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

// A clean, modern story camera — tap the shutter for a photo, hold to record video —
// then a composer to add a song and a caption before sharing. No filters, no edit
// tools: just capture → caption → song → share, smooth and minimal.

// MARK: - Capture engine

@MainActor
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "haven.camera")

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
    @State private var captionSpec = StoryCaptions.Spec()
    @State private var musicStartMs = 0.0
    @State private var songPreviewing = false
    @State private var kbHeight: CGFloat = 0   // live keyboard height (the editor ignores the safe area)
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media.ignoresSafeArea()

            // A full-screen tap layer to start/stop editing (behind the controls).
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    if editingCaption { captionFocused = false; editingCaption = false }
                    else { editingCaption = true }
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
                topControls
                Spacer()
                if editingCaption { captionStyleControls.padding(.bottom, 10) }
                if let track {
                    nowPlayingChip(track)
                    if track.durationMs > 16000 { musicSectionSlider(track) }
                }
                if !editingCaption { shareBar }
            }
            .padding(.bottom, editingCaption ? kbHeight : 0)   // keep the style controls above the keyboard
            .animation(.easeOut(duration: 0.25), value: kbHeight)
        }
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { kbHeight = f.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in kbHeight = 0 }
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
            controlButton("Aa", system: nil) {
                editingCaption = true
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

    /// Caption editing controls: tap-through typography, highlight toggle, color row.
    private var captionStyleControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { captionSpec.cycleFont() } label: {
                    Text("Aa").font(.headline.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.black.opacity(0.4), in: Circle())
                }
                Button { captionSpec.highlight.toggle() } label: {
                    Image(systemName: captionSpec.highlight ? "a.square.fill" : "a.square")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.black.opacity(0.4), in: Circle())
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
                onShare(draft.mediaRef, StoryCaptions.encode(caption, captionSpec), trackForShare())
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text("Share to story").font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(HavenTheme.brandHorizontal, in: Capsule())
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
