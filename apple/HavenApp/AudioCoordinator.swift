import SwiftUI
import AVFoundation
import MediaPlayer
import MusicKit

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

    /// Begin a post's audio. If a song is attached it plays (video muted). Otherwise the
    /// author's `muteVideo` choice decides: off → the video plays its own audio; on → silent.
    func start(postId: String, track: TrackRefFfi?, video: AVPlayer?, muteVideo: Bool = false) {
        if activePostId == postId { return }
        stop()
        activePostId = postId
        videoPlayer = video
        // Play the video's own audio only when there's no song, the author left it unmuted,
        // and the app isn't globally silenced.
        let playVideoAudio = (track == nil) && !muteVideo && !SettingsStore.shared.silent
        videoUnmuted = playVideoAudio
        video?.volume = playVideoAudio ? 1 : 0
        if let track { MusicPlayback.shared.play(track) }
    }

    /// Tap-to-toggle a music-only post's sound (pause/resume the song).
    func toggleMusic(postId: String, track: TrackRefFfi?) {
        guard !SettingsStore.shared.silent else { return }
        if activePostId != postId { start(postId: postId, track: track, video: nil) }
        if MusicPlayback.shared.isPlaying { MusicPlayback.shared.duck() }
        else { MusicPlayback.shared.resume() }
    }

    /// Globally mute/unmute the app (post music + video audio).
    func setSilent(_ on: Bool) {
        if on {
            MusicPlayback.shared.duck()
            videoPlayer?.volume = 0
            videoUnmuted = false
        } else {
            // Unmute must actually (re)start audio for the active post — not just flip a flag.
            // If a song is attached but was never queued (play() bails while silent), `resume()`
            // has nothing to resume; reissue a full play so the track loads and starts.
            if MusicPlayback.shared.current != nil {
                MusicPlayback.shared.restartCurrent()
            } else {
                // No song: bring the active post's video audio back up (author/global allowing).
                videoPlayer?.volume = 1
                videoUnmuted = videoPlayer != nil
            }
        }
    }

    /// Toggle the video's own audio, crossfading against the song.
    func toggleVideoAudio() {
        guard !SettingsStore.shared.silent else { return }   // app is muted
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

    /// Pause all feed playback when the app backgrounds (a call's own audio is separate).
    func pauseForBackground() {
        MusicPlayback.shared.duck()
        videoPlayer?.pause()
    }

    /// Make sure the active post's song is playing — unless the viewer is intentionally
    /// listening to a video's audio. Called when a post stays active (e.g. after a video
    /// paused it) so the music resumes as long as you haven't scrolled past the post.
    func ensureMusicPlaying() {
        guard !videoUnmuted, !SettingsStore.shared.silent else { return }
        MusicPlayback.shared.resume()
    }

    /// The active post's video finished playing — re-mute it and bring the song back.
    func videoFinished() {
        if videoUnmuted {
            videoUnmuted = false
            videoPlayer?.volume = 0
        }
        MusicPlayback.shared.resume()
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

#if os(macOS)
/// Native macOS Apple Music playback via MusicKit's `ApplicationMusicPlayer` (macOS 14+).
/// `MPMusicPlayerController`/`MPMediaItem` don't exist on macOS, so we can only play CATALOG
/// songs (a store id) — there's no local-library item lookup. A shared song carries only its
/// catalog id; we queue that id so it plays through the viewer's own Apple Music subscription.
/// When the viewer unmutes a post's video the song pauses (duck) and resumes (unduck) on re-mute.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()
    private(set) var current: TrackRefFfi?
    private let player = ApplicationMusicPlayer.shared
    private var authed = false

    var isPlaying: Bool { player.state.playbackStatus == .playing }

    func play(_ track: TrackRefFfi) {
        current = track
        guard !SettingsStore.shared.silent else { return }   // app is muted
        let ids = trackIds(track.catalogId)
        // macOS can only play catalog songs — a store id is required (no MPMediaItem library).
        guard let store = ids.store, !store.isEmpty else { return }
        // Stories can pick a section of the song (start offset encoded as "start:<ms>").
        let startSeconds: Double? = {
            guard track.artworkUrl.hasPrefix("start:"),
                  let ms = Double(track.artworkUrl.dropFirst(6)), ms > 0 else { return nil }
            return ms / 1000
        }()
        Task { @MainActor in
            // Catalog playback needs MusicKit authorization (requested once).
            if !authed {
                _ = await MusicAuthorization.request()
                authed = true
            }
            // Bail if the track was swapped out or the app muted while we awaited auth.
            guard current?.catalogId == track.catalogId, !SettingsStore.shared.silent else { return }
            do {
                let id = MusicItemID(store)
                var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
                request.limit = 1
                let response = try await request.response()
                guard let song = response.items.first else { return }
                // Re-check after the network fetch; user may have scrolled / muted.
                guard current?.catalogId == track.catalogId, !SettingsStore.shared.silent else { return }
                player.queue = [song]
                try await player.play()
                if let startSeconds {
                    player.playbackTime = startSeconds
                }
            } catch {
                // Never crash on playback failure (no subscription, offline, etc.).
            }
        }
    }
    func duck() {
        if player.state.playbackStatus == .playing { player.pause() }
    }
    func unduck() {
        guard current != nil else { return }
        Task { @MainActor in try? await player.play() }
    }
    /// Resume the queued song if it's paused (e.g. a video had ducked it).
    func resume() {
        guard current != nil, player.state.playbackStatus != .playing else { return }
        Task { @MainActor in try? await player.play() }
    }
    /// Fully (re)queue and start the current track — used on unmute, when the song may never
    /// have been queued (play() bails while the app is silent, so resume() has nothing to do).
    func restartCurrent() {
        guard let track = current else { return }
        play(track)
    }
    func stop() {
        current = nil
        if player.state.playbackStatus == .playing { player.pause() }
    }
}
#else
/// Real Apple Music playback via the system music player. A shared song carries only
/// its catalog id; we queue that id so it plays through the viewer's own Apple Music
/// subscription — Haven never moves audio. When the viewer unmutes a post's video the
/// song pauses (duck) and resumes (unduck) on re-mute.
@MainActor
final class MusicPlayback {
    static let shared = MusicPlayback()
    private(set) var current: TrackRefFfi?
    private let player = MPMusicPlayerController.applicationMusicPlayer
    private var authed = false
    var isPlaying: Bool { player.playbackState == .playing }

    func play(_ track: TrackRefFfi) {
        current = track
        guard !SettingsStore.shared.silent else { return }   // app is muted
        let ids = trackIds(track.catalogId)
        guard ids.store != nil || ids.pid != nil else { return }
        // Playing through the system player needs media-library authorization.
        if !authed {
            MPMediaLibrary.requestAuthorization { _ in }
            authed = true
        }
        if let pid = ids.pid, let item = librarySong(pid) {
            // Exact local song — queue just this one item (no neighbors).
            player.setQueue(with: MPMediaItemCollection(items: [item]))
        } else if let store = ids.store {
            // Catalog song (e.g. on a recipient's device) — queue by store id.
            player.setQueue(with: [store])
        } else {
            return
        }
        player.play()
        // Stories can pick a section of the song (start offset encoded as "start:<ms>").
        if track.artworkUrl.hasPrefix("start:"), let ms = Double(track.artworkUrl.dropFirst(6)), ms > 0 {
            player.currentPlaybackTime = ms / 1000
        }
    }
    func duck() {
        if player.playbackState == .playing { player.pause() }
    }
    func unduck() {
        if current != nil { player.play() }
    }
    /// Resume the queued song if it's paused (e.g. a video had ducked it).
    func resume() {
        guard current != nil, player.playbackState != .playing else { return }
        player.play()
    }
    /// Fully (re)queue and start the current track — used on unmute, when the song may never
    /// have been queued (play() bails while the app is silent, so resume() has nothing to do).
    func restartCurrent() {
        guard let track = current else { return }
        play(track)
    }
    func stop() {
        current = nil
        if player.playbackState == .playing { player.pause() }
    }
}
#endif
