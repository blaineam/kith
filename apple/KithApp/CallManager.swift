import Foundation
import AVFoundation
import SwiftUI
import UIKit
import CoreImage
#if !targetEnvironment(macCatalyst)
import CallKit
#endif

#if targetEnvironment(macCatalyst)
/// CallKit is unavailable on Mac Catalyst — calls are an iOS feature in v1.
@MainActor
final class CallManager: ObservableObject {
    static let shared = CallManager()
    @Published private(set) var inCall = false
    @Published private(set) var connecting = false
    @Published private(set) var ringing = false
    @Published private(set) var peerName = ""
    func startCall(peerHex: String, name: String) {}
    func handleInvite(_ payload: Data) {}
    func handleAccept(_ payload: Data) {}
    func handleHangup(_ payload: Data) {}
    func handleAudio(_ payload: Data) {}
    func handleVideo(_ payload: Data) {}
    func endCall() {}
}
struct CallOverlay: View { var body: some View { EmptyView() } }
#else

/// Peer-to-peer voice calls. Signaling (invite / accept / hangup) and the audio itself
/// travel over Kith's existing direct P2P transport (iroh QUIC) — no call server, no
/// third party in the path. CallKit provides the native call UI. Audio is captured with
/// AVAudioEngine, downsampled to 16 kHz mono, and streamed as frames to the peer, who
/// plays it back. (Video calls + on-device A/V tuning are the follow-on.)
///
/// Frame types on the wire: 10 invite [hex64][name] · 11 accept [hex64] ·
/// 12 hangup [hex64] · 13 audio [hex64][int16 pcm].
@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published private(set) var inCall = false
    @Published private(set) var connecting = false
    @Published private(set) var peerName = ""
    /// Whether our camera is on, and the latest decoded frame from the peer.
    @Published private(set) var videoOn = false
    @Published private(set) var remoteFrame: UIImage?
    @Published private(set) var localFrame: UIImage?     // our own camera, for the PiP preview
    /// An incoming call is ringing (drives the in-app accept/decline UI, independent of CallKit).
    @Published private(set) var ringing = false
    @Published private(set) var speakerOn = false

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callId: UUID?
    private var peerHex = ""
    private let videoCapturer = VideoCapturer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var audioRunning = false

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    private var myHex: String { FeedStore.shared.myNodeHex }
    private var myName: String {
        let n = ProfileStore.shared.displayName
        return n.isEmpty ? "Someone" : n
    }

    // MARK: - Outgoing

    func startCall(peerHex: String, name: String) {
        guard callId == nil else { return }
        self.peerHex = peerHex; self.peerName = name; connecting = true
        let id = UUID(); callId = id
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
        controller.request(CXTransaction(action: action)) { _ in }
        var invite = Data(myHex.utf8); invite.append(Data(myName.utf8))
        FeedStore.shared.sendCallFrame(10, invite, to: peerHex)
    }

    // MARK: - Inbound signaling

    func handleInvite(_ payload: Data) {
        guard callId == nil, payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        let name = String(data: payload.dropFirst(64), encoding: .utf8) ?? "Someone"
        guard from.count == 64 else { return }
        peerHex = from; peerName = name
        let id = UUID(); callId = id
        ringing = true   // show the in-app incoming-call UI no matter what CallKit does
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { _ in }
    }

    /// Accept an incoming call from the in-app UI (works even if CallKit's UI never showed).
    func accept() {
        guard ringing else { return }
        ringing = false; inCall = true
        FeedStore.shared.sendCallFrame(11, Data(myHex.utf8), to: peerHex)
        startAudio()
    }
    /// Decline a ringing call.
    func decline() {
        guard ringing else { return }
        if !peerHex.isEmpty { FeedStore.shared.sendCallFrame(12, Data(myHex.utf8), to: peerHex) }
        teardown()
    }

    /// Flip between front and back camera mid-call.
    func flipCamera() { if videoOn { videoCapturer.flip() } }

    /// Route audio to the speaker (audio-only calls) or back to the earpiece.
    func toggleSpeaker() {
        speakerOn.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }

    func handleAccept(_ payload: Data) {
        guard connecting, let id = callId else { return }
        connecting = false; inCall = true
        provider.reportOutgoingCall(with: id, connectedAt: nil)
        startAudio()
    }

    func handleHangup(_ payload: Data) {
        guard let id = callId else { return }
        provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
        teardown()
    }

    func handleAudio(_ payload: Data) {
        guard inCall, payload.count > 64 else { return }
        play(payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex))
    }

    // MARK: - Video (optional, toggled on during a call)

    /// Turn our camera on/off mid-call. Frames are captured, downscaled to ~240px,
    /// JPEG-encoded at ~10fps, and streamed to the peer over frame type 15.
    func toggleVideo() {
        if videoOn {
            videoOn = false; localFrame = nil
            videoCapturer.stop()
            return
        }
        guard inCall || connecting else { return }
        // Camera needs explicit permission the first time, or start() silently no-ops.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in
                guard let self else { return }
                self.videoCapturer.onFrame = { [weak self] jpeg in
                    Task { @MainActor in
                        self?.sendVideo(jpeg)
                        self?.localFrame = UIImage(data: jpeg)   // our own camera → PiP preview
                    }
                }
                self.videoCapturer.start()
                self.videoOn = true
            }
        }
    }

    private func sendVideo(_ jpeg: Data) {
        guard inCall, !peerHex.isEmpty else { return }
        var f = Data(myHex.utf8); f.append(jpeg)
        FeedStore.shared.sendCallFrame(15, f, to: peerHex)
    }

    func handleVideo(_ payload: Data) {
        guard inCall, payload.count > 64 else { return }
        let jpeg = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        if let img = UIImage(data: jpeg) { remoteFrame = img }
    }

    // MARK: - End

    func endCall() {
        // Ask CallKit to end it, but ALSO tear down locally + tell the peer — so the call
        // screen always dismisses even if CallKit never fulfills the action.
        if let id = callId { controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in } }
        if !peerHex.isEmpty { FeedStore.shared.sendCallFrame(12, Data(myHex.utf8), to: peerHex) }
        teardown()
    }

    private func teardown() {
        stopAudio()
        if videoOn { videoCapturer.stop() }
        if speakerOn { try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none) }
        videoOn = false; remoteFrame = nil; localFrame = nil; ringing = false; speakerOn = false
        callId = nil; inCall = false; connecting = false; peerHex = ""; peerName = ""
    }

    // MARK: - Audio path

    private func startAudio() {
        guard !audioRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch { return }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: wireFormat) else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.wireFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
            guard let out = AVAudioPCMBuffer(pcmFormat: self.wireFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
            Task { @MainActor [weak self] in self?.sendAudio(data) }
        }

        engine.prepare()
        do { try engine.start(); player.play(); audioRunning = true } catch { audioRunning = false }
    }

    private func stopAudio() {
        guard audioRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioRunning = false
    }

    private func sendAudio(_ pcm: Data) {
        guard inCall, !peerHex.isEmpty else { return }
        var f = Data(myHex.utf8); f.append(pcm)
        FeedStore.shared.sendCallFrame(13, f, to: peerHex)
    }

    /// Play received int16 PCM by converting to the float playback format.
    private func play(_ pcm: Data) {
        guard audioRunning else { return }
        let count = pcm.count / MemoryLayout<Int16>.size
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        buf.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<count { dst[i] = Float(src[i]) / 32768.0 }
        }
        player.scheduleBuffer(buf, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}

/// Captures front-camera frames off the main actor, throttles to ~10fps, downscales to
/// ~240px and JPEG-encodes them, handing each frame back via `onFrame` (called on its own
/// serial queue). Kept separate from the @MainActor CallManager so the hot capture path
/// never touches the main thread.
final class VideoCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "kith.call.video")
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private var lastSend: CFTimeInterval = 0
    private var position: AVCaptureDevice.Position = .front
    var onFrame: ((Data) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .low
            self.configureInput()
            if self.session.outputs.isEmpty {
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            }
            self.applyOrientation()
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    /// Swap between the front and back camera.
    func flip() {
        queue.async { [weak self] in
            guard let self else { return }
            self.position = (self.position == .front) ? .back : .front
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.configureInput()
            self.applyOrientation()
            self.session.commitConfiguration()
        }
    }

    private func configureInput() {
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else { return }
        session.addInput(input)
    }

    /// Upright (portrait) frames + mirror the front camera so the preview reads naturally.
    private func applyOrientation() {
        guard let conn = output.connection(with: .video) else { return }
        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (position == .front)
        }
    }

    func stop() { queue.async { [weak self] in if self?.session.isRunning == true { self?.session.stopRunning() } } }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastSend > 0.1 else { return }          // ~10fps
        lastSend = now
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let w = ci.extent.width
        guard w > 0 else { return }
        let scale = 240.0 / w
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ctx.createCGImage(small, from: small.extent) else { return }
        if let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.4) { onFrame?(jpeg) }
    }
}

/// A minimal in-call overlay (CallKit shows the system UI; this is the in-app banner).
/// When video is on (locally or from the peer) the remote frame fills the screen.
struct CallOverlay: View {
    @ObservedObject private var call = CallManager.shared
    var body: some View {
        if call.ringing {
            incoming
        } else if call.inCall || call.connecting {
            active
        }
    }

    private var incoming: some View {
        ZStack {
            HavenTheme.brand.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "phone.fill.arrow.down.left").font(.system(size: 40)).foregroundStyle(.white)
                Text(call.peerName.isEmpty ? "Call" : call.peerName).font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text("Incoming call…").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                Spacer()
                HStack(spacing: 60) {
                    Button { CallManager.shared.decline() } label: {
                        Image(systemName: "phone.down.fill").font(.title).foregroundStyle(.white)
                            .frame(width: 70, height: 70).background(Color.red, in: Circle())
                    }
                    Button { CallManager.shared.accept() } label: {
                        Image(systemName: "phone.fill").font(.title).foregroundStyle(.white)
                            .frame(width: 70, height: 70).background(Color.green, in: Circle())
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        .transition(.move(edge: .bottom))
    }

    private var active: some View {
        ZStack {
            if let frame = call.remoteFrame {
                Image(uiImage: frame).resizable().scaledToFill().ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            } else {
                HavenTheme.brand.opacity(0.96).ignoresSafeArea()
            }
            // Local camera preview (picture-in-picture) when our video is on.
            if let mine = call.localFrame {
                VStack {
                    HStack {
                        Spacer()
                        Image(uiImage: mine).resizable().scaledToFill()
                            .frame(width: 96, height: 128).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.6)))
                            .padding(.top, 60).padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
            VStack(spacing: 16) {
                Spacer()
                if call.remoteFrame == nil {
                    Image(systemName: "phone.fill.arrow.up.right").font(.system(size: 40)).foregroundStyle(.white)
                }
                Text(call.peerName.isEmpty ? "Call" : call.peerName).font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text(call.connecting ? "Calling…" : "Connected").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                Spacer()
                HStack(spacing: 28) {
                    Button { CallManager.shared.toggleSpeaker() } label: {
                        callButton(call.speakerOn ? "speaker.wave.3.fill" : "speaker.fill", on: call.speakerOn)
                    }
                    Button { CallManager.shared.toggleVideo() } label: {
                        callButton(call.videoOn ? "video.fill" : "video.slash.fill", on: call.videoOn)
                    }
                    if call.videoOn {
                        Button { CallManager.shared.flipCamera() } label: {
                            callButton("arrow.triangle.2.circlepath.camera.fill", on: false)
                        }
                    }
                    Button { CallManager.shared.endCall() } label: {
                        Image(systemName: "phone.down.fill").font(.title)
                            .foregroundStyle(.white).frame(width: 70, height: 70)
                            .background(Color.red, in: Circle())
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        .transition(.move(edge: .bottom))
    }

    private func callButton(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(.title2).foregroundStyle(.white).frame(width: 64, height: 64)
            .background(on ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
    }
}

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.teardown() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.inCall = true; self.connecting = false
            FeedStore.shared.sendCallFrame(11, Data(self.myHex.utf8), to: self.peerHex)
            self.startAudio()
            action.fulfill()
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            if let id = self.callId { provider.reportOutgoingCall(with: id, startedConnectingAt: nil) }
            action.fulfill()
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if !self.peerHex.isEmpty { FeedStore.shared.sendCallFrame(12, Data(self.myHex.utf8), to: self.peerHex) }
            self.teardown()
            action.fulfill()
        }
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
#endif
