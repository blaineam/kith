import SwiftUI
import AVFoundation

/// Records a short audio reply to a temp file. Mic permission is the existing
/// NSMicrophoneUsageDescription. The recording is treated like any other media —
/// sealed E2E before it's sent.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var url: URL?

    func start() {
        // AVAudioSession is iOS/Catalyst-only; macOS records without a session.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        #endif
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        recorder = try? AVAudioRecorder(url: u, settings: settings)
        recorder?.record()
        url = u
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.elapsed += 0.1 }
        }
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop(); recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        return url
    }
}

/// A tap-to-record sheet for an audio reply.
struct AudioRecorderView: View {
    var onDone: (String) -> Void
    @StateObject private var rec = AudioRecorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            HavenBackground()
            VStack(spacing: 24) {
                Text(rec.isRecording ? "Recording…" : "Record an audio reply")
                    .font(.headline)
                Text(String(format: "%0.1fs", rec.elapsed))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rec.isRecording ? HavenTheme.pink : .secondary)
                EqualizerBars(animating: rec.isRecording).frame(width: 60, height: 30)

                Button {
                    if rec.isRecording {
                        if let u = rec.stop() { onDone(MediaStore.shared.addAudio(url: u)); dismiss() }
                    } else {
                        AVAudioApplication.requestRecordPermission { _ in }
                        rec.start()
                    }
                } label: {
                    Image(systemName: rec.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(HavenTheme.brand)
                }
                Button("Cancel") { rec.stop(); dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        }
        .presentationDetents([.medium])
    }
}

/// A small play/pause pill for an audio reply.
struct AudioPlayerPill: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                EqualizerBars(animating: playing)
                Text("Audio").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(HavenTheme.pink.opacity(0.35)))
        }
        .buttonStyle(PressableStyle())
    }

    private func toggle() {
        if playing {
            player?.pause(); playing = false
        } else {
            if player == nil {
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                #endif
                player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }
            player?.play(); playing = true
        }
    }
}
