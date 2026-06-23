import Foundation
import CoreVideo
import WebRTC

#if targetEnvironment(macCatalyst)
import ScreenCaptureKit
import CoreMedia
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
import ReplayKit
#endif

/// A single shareable source the user can pick from on macOS — a whole display or one window.
struct ScreenSource: Identifiable, Hashable {
    enum Kind: Hashable { case display, window }
    let id: String          // stable id ("display:<n>" / "window:<n>")
    let kind: Kind
    let title: String       // e.g. "Built-in Retina Display" / "Safari — Apple"
    let subtitle: String    // app name for windows, resolution for displays
}

/// Captures the screen and hands raw `CVPixelBuffer` frames to a callback. The CallManager wires
/// that callback to push the frames into every mesh peer's WebRTC screen track.
///
/// - macOS (Mac Catalyst): uses **ScreenCaptureKit**. `availableSources()` enumerates every display
///   and on-screen window via `SCShareableContent`; `start(source:)` spins up an `SCStream`.
/// - iOS: a **ReplayKit broadcast upload extension** captures system-wide frames and pipes them to
///   the app through an App Group; see `BroadcastFrameReceiver`. The picker is presented from the UI
///   via `RPSystemBroadcastPickerView`.
@MainActor
final class ScreenShareManager: NSObject {
    static let shared = ScreenShareManager()

    /// Fired (on the main actor) for every captured frame while sharing is active.
    var onFrame: ((_ pixelBuffer: CVPixelBuffer, _ timeStampNs: Int64) -> Void)?
    /// Fired when capture stops for any reason (user stopped, stream error, source closed).
    var onStop: (() -> Void)?

    private(set) var isSharing = false

    #if targetEnvironment(macCatalyst)
    // The SCStream + its delegate live in a separately-gated object (SCStream is Catalyst 18.2+),
    // stored as `AnyObject?` so this property declaration carries no availability floor.
    private var capture: AnyObject?
    #endif

    // MARK: - macOS: enumerate displays + windows

    #if targetEnvironment(macCatalyst)
    /// All shareable displays and windows (title + owning app). Empty if permission is denied.
    @available(macCatalyst 18.2, *)
    func availableSources() async -> [ScreenSource] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                              onScreenWindowsOnly: true)
            var sources: [ScreenSource] = []
            for d in content.displays {
                sources.append(ScreenSource(id: "display:\(d.displayID)", kind: .display,
                                            title: "Display \(d.displayID)",
                                            subtitle: "\(d.width) × \(d.height)"))
            }
            for w in content.windows {
                // Skip tiny/util windows and our own windows.
                guard let title = w.title, !title.isEmpty,
                      w.frame.width > 80, w.frame.height > 80 else { continue }
                let app = w.owningApplication?.applicationName ?? "App"
                sources.append(ScreenSource(id: "window:\(w.windowID)", kind: .window,
                                            title: title, subtitle: app))
            }
            return sources
        } catch {
            return []
        }
    }

    /// Start an SCStream for the picked source.
    @available(macCatalyst 18.2, *)
    func start(source: ScreenSource) async {
        guard !isSharing else { return }
        let capturer = SCCapturer()
        capturer.onFrame = { [weak self] pb, ts in
            Task { @MainActor in self?.onFrame?(pb, ts) }
        }
        capturer.onStop = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        let ok = await capturer.start(source: source)
        guard ok else { onStop?(); return }
        capture = capturer
        isSharing = true
    }

    func stop() {
        guard isSharing else { return }
        isSharing = false
        let c = capture
        capture = nil
        if #available(macCatalyst 18.2, *), let capturer = c as? SCCapturer {
            Task { await capturer.stop(); self.onStop?() }
        } else {
            onStop?()
        }
    }
    #endif

    // MARK: - Native macOS: screen share via ScreenCaptureKit is Phase 2 (stub for now)

    #if os(macOS)
    func stop() {
        guard isSharing else { return }
        isSharing = false
        onStop?()
    }
    #endif

    // MARK: - iOS: receive frames piped from the broadcast extension

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var broadcastReceiver: BroadcastFrameReceiver?

    /// Begin listening for frames from the ReplayKit broadcast extension (the user starts the actual
    /// broadcast via the system picker). Frames arrive over the App Group shared container.
    func startListeningForBroadcast() {
        guard !isSharing else { return }
        isSharing = true
        let receiver = BroadcastFrameReceiver()
        receiver.onFrame = { [weak self] pb, ts in
            Task { @MainActor in self?.onFrame?(pb, ts) }
        }
        receiver.onStop = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        receiver.start()
        broadcastReceiver = receiver
    }

    func stop() {
        guard isSharing else { return }
        isSharing = false
        broadcastReceiver?.stop()
        broadcastReceiver = nil
        onStop?()
    }
    #endif
}

#if targetEnvironment(macCatalyst)
/// Owns one `SCStream` + its delegate, fully gated to Catalyst 18.2 (the floor for ScreenCaptureKit
/// on Catalyst). Forwards complete frames as `CVPixelBuffer`s via `onFrame`.
@available(macCatalyst 18.2, *)
final class SCCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    var onStop: (() -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "haven.screenshare.sck")

    /// Build the content filter + config for the source and start capturing. Returns false on error.
    func start(source: ScreenSource) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                              onScreenWindowsOnly: true)
            let filter: SCContentFilter
            let config = SCStreamConfiguration()
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

            switch source.kind {
            case .display:
                let displayID = UInt32(source.id.replacingOccurrences(of: "display:", with: "")) ?? 0
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else { return false }
                filter = SCContentFilter(display: display, excludingWindows: [])
                config.width = display.width
                config.height = display.height
            case .window:
                let windowID = UInt32(source.id.replacingOccurrences(of: "window:", with: "")) ?? 0
                guard let window = content.windows.first(where: { $0.windowID == windowID })
                else { return false }
                filter = SCContentFilter(desktopIndependentWindow: window)
                config.width = max(Int(window.frame.width), 2)
                config.height = max(Int(window.frame.height), 2)
            }

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
            return true
        } catch {
            return false
        }
    }

    func stop() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
    }

    // MARK: SCStreamDelegate / SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // SCStream marks complete/idle frames in the attachments; only forward complete frames.
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                          createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachmentsArray.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
        onFrame?(pixelBuffer, ts)
    }
}
#endif
