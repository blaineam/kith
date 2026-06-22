import SwiftUI
import AVFoundation
import UIKit

/// A simple, intuitive in-app camera: tap the shutter for a photo, hold it to record
/// video, tap to flip. Captures stay on-device (sandbox), registered in `MediaStore`
/// and only ever sent after being sealed E2E. (AVCaptureSession needs a real device.)
struct CameraView: UIViewControllerRepresentable {
    var onCaptured: ([String]) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCaptured = onCaptured
        return vc
    }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {}
}

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
        b.setImage(UIImage(systemName: symbol), for: .normal)
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
        guard let data = photo.fileDataRepresentation(), let img = UIImage(data: data) else { return }
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
        // If the user has Save to Photos on, captured media lands in their library too.
        for ref in refs {
            if let item = MediaStore.shared.item(ref) { PhotoSaver.saveIfEnabled(item) }
        }
        onCaptured?(refs)
        dismiss(animated: true)
    }
}
