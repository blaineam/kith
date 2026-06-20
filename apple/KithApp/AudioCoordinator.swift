import SwiftUI
import AVFoundation
import MediaPlayer

/// Coordinates a post's audio: the attached song plays while its video stays muted.
/// When the viewer unmutes the video, the music fades down as the video fades up — a
/// clean crossfade — and back the other way on re-mute. Only one post is audible at a
/// time. No network, no data: this is local playback only.
@MainActor
final class AudioCoordinator: ObservableObject {
    static let shared = AudioCoordinator()

    @Published private(set) var activePostId: String?
    @Published private(set) var videoUnmuted = false
    /// The post currently centered in the feed (drives which post's media plays).
    @Published var centeredPostId: String?

    /// Called by the feed as the user scrolls; one post is "centered" at a time.
    func center(_ id: String?) {
        guard centeredPostId != id else { return }
        centeredPostId = id
    }

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

/// Real Apple Music playback via the system music player. A shared song carries only
/// its catalog id; we queue that id so it plays through the viewer's own Apple Music
/// subscription — Kith never moves audio. When the viewer unmutes a post's video the
/// song pauses (duck) and resumes (unduck) on re-mute.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()
    private(set) var current: TrackRefFfi?
    private let player = MPMusicPlayerController.applicationMusicPlayer

    func play(_ track: TrackRefFfi) {
        current = track
        // Only catalog (store) songs are playable by id; library-only items have no id.
        guard !track.catalogId.isEmpty, track.catalogId != "0" else { return }
        player.setQueue(with: [track.catalogId])
        player.play()
    }
    func duck() {
        if player.playbackState == .playing { player.pause() }
    }
    func unduck() {
        if current != nil { player.play() }
    }
    func stop() {
        current = nil
        if player.playbackState == .playing { player.pause() }
    }
}
