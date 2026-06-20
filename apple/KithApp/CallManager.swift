import Foundation
import AVFoundation
import SwiftUI
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
    @Published private(set) var peerName = ""
    func startCall(peerHex: String, name: String) {}
    func handleInvite(_ payload: Data) {}
    func handleAccept(_ payload: Data) {}
    func handleHangup(_ payload: Data) {}
    func handleAudio(_ payload: Data) {}
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

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callId: UUID?
    private var peerHex = ""

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
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { _ in }
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

    // MARK: - End

    func endCall() {
        guard let id = callId else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in }
    }

    private func teardown() {
        stopAudio()
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

/// A minimal in-call overlay (CallKit shows the system UI; this is the in-app banner).
struct CallOverlay: View {
    @ObservedObject private var call = CallManager.shared
    var body: some View {
        if call.inCall || call.connecting {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "phone.fill.arrow.up.right").font(.system(size: 40)).foregroundStyle(.white)
                Text(call.peerName.isEmpty ? "Call" : call.peerName).font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text(call.connecting ? "Calling…" : "Connected").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { CallManager.shared.endCall() } label: {
                    Image(systemName: "phone.down.fill").font(.title)
                        .foregroundStyle(.white).frame(width: 70, height: 70)
                        .background(Color.red, in: Circle())
                }
                .padding(.bottom, 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KithTheme.brand.opacity(0.96))
            .ignoresSafeArea()
            .transition(.move(edge: .bottom))
        }
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
