import SwiftUI
import AVFoundation

/// Coordinates a post's audio: the attached song plays while its video stays muted.
/// When the viewer unmutes the video, the music fades down as the video fades up — a
/// clean crossfade — and back the other way on re-mute. Only one post is audible at a
/// time. No network, no data: this is local playback only.
@MainActor
final class AudioCoordinator: ObservableObject {
    static let shared = AudioCoordinator()

    @Published private(set) var activePostId: String?
    @Published private(set) var videoUnmuted = false

    private var videoPlayer: AVPlayer?
    private var fadeTimer: Timer?

    /// Begin a post's audio: start the song, keep the video muted.
    func start(postId: String, track: TrackRefFfi?, video: AVPlayer?) {
        if activePostId == postId { return }
        stop()
        activePostId = postId
        videoUnmuted = false
        videoPlayer = video
        video?.volume = 0
        if let track { MusicPlayback.shared.play(track) }
    }

    /// Toggle the video's own audio, crossfading against the song.
    func toggleVideoAudio() {
        videoUnmuted.toggle()
        if videoUnmuted {
            MusicPlayback.shared.duck()              // music down
            fadeVideo(to: 1.0)                        // video up
        } else {
            fadeVideo(to: 0.0)                        // video down
            MusicPlayback.shared.unduck()             // music back up
        }
    }

    func stop() {
        fadeTimer?.invalidate(); fadeTimer = nil
        videoPlayer?.volume = 0
        videoPlayer = nil
        MusicPlayback.shared.stop()
        activePostId = nil
        videoUnmuted = false
    }

    private func fadeVideo(to target: Float, duration: TimeInterval = 0.45) {
        guard let player = videoPlayer else { return }
        fadeTimer?.invalidate()
        let steps = 18
        let start = player.volume
        var i = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { timer in
            i += 1
            let p = Float(i) / Float(steps)
            Task { @MainActor in player.volume = start + (target - start) * p }
            if i >= steps { timer.invalidate() }
        }
    }
}

/// The Apple Music playback seam. Volume ducking is structured here; the actual
/// `ApplicationMusicPlayer` calls light up once the **MusicKit capability** is enabled
/// on the App ID and a subscriber runs it on device. Until then these are no-ops, so
/// the rest of the experience (now-playing pill, video crossfade) works everywhere.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()
    private(set) var current: TrackRefFfi?

    func play(_ track: TrackRefFfi) {
        current = track
        // MusicKit: resolve Song(id: track.catalogId) → ApplicationMusicPlayer.shared.queue → play()
    }
    func duck() {
        // MusicKit: fade ApplicationMusicPlayer toward silence / pause
    }
    func unduck() {
        // MusicKit: resume / fade ApplicationMusicPlayer back up
    }
    func stop() {
        current = nil
        // MusicKit: ApplicationMusicPlayer.shared.stop()
    }
}
