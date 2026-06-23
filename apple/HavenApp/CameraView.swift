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

    var body: some View {
        CameraCaptureRepresentable { refs in
            reviewRefs = refs
        }
        .ignoresSafeArea()
        .havenFullScreenCover(item: Binding(get: { reviewRefs.map { CaptureBatch(refs: $0) } },
                                       set: { reviewRefs = $0?.refs })) { batch in
            CaptureReviewView(refs: batch.refs) { finalRefs in
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
    var onCaptured: ([String]) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCaptured = onCaptured
        return vc
    }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {}
}
#endif

#if os(macOS)
/// macOS placeholder for the camera capture surface. Native AVCaptureSession camera UI is
/// Phase-2 work; for now this renders a non-functional placeholder and never invokes `onCaptured`.
struct CameraCaptureRepresentable: View {
    var onCaptured: ([String]) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.85))
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 40, weight: .semibold))
                Text("Camera isn't available on Mac yet")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
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

    @State private var filter: HavenFilter = .original
    @State private var working = false

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

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var preview: AVCaptureVideoPreviewLayer!
    private var position: AVCaptureDevice.Position = .back
    private let shutter = UIButton(type: .system)
    private let ring = UIView()

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
        if session.isRunning { session.stopRunning() }
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
        session.commitConfiguration()

        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)

        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
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
        shutter.addTarget(self, action: #selector(tapShutter), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdShutter(_:)))
        hold.minimumPressDuration = 0.35
        shutter.addGestureRecognizer(hold)
        view.addSubview(shutter)

        let flip = button(symbol: "arrow.triangle.2.circlepath.camera", action: #selector(flip))
        let close = button(symbol: "xmark", action: #selector(closeTapped))
        view.addSubview(flip); view.addSubview(close)

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

    @objc private func tapShutter() {
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    @objc private func holdShutter(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            movieOutput.startRecording(to: url, recordingDelegate: self)
            ring.layer.borderColor = UIColor.systemPink.cgColor
        case .ended, .cancelled, .failed:
            if movieOutput.isRecording { movieOutput.stopRecording() }
            ring.layer.borderColor = UIColor.white.cgColor
        default: break
        }
    }

    @objc private func flip() {
        position = (position == .back) ? .front : .back
        session.beginConfiguration()
        addCameraInput(position: position)
        session.commitConfiguration()
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
