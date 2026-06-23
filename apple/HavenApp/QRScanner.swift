import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if !os(macOS)
/// A live camera QR scanner. Calls `onFound` once with the decoded string, then the
/// caller dismisses. Reads both `https://…/#…` and `haven://invite#…` invite links.
struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onFound = { context.coordinator.handle($0) }
        return vc
    }

    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class Coordinator {
        private let onFound: (String) -> Void
        private var fired = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }
        func handle(_ code: String) {
            guard !fired else { return }
            fired = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound(code)
        }
    }
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue, !value.isEmpty else { return }
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }
        onFound?(value)
    }
}
#endif

#if os(macOS)
/// macOS placeholder. The live camera QR scanner is Phase-2 native work; this stub
/// keeps the public surface identical to the iOS version but renders a notice instead
/// of scanning. It never invokes `onFound`.
struct QRScannerView: View {
    var onFound: (String) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
            VStack(spacing: 16) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                Text("Scanning isn't available on Mac yet")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
#endif
