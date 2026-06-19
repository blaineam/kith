import SwiftUI

/// A few sample songs so the music-on-posts experience is demonstrable today. Each
/// is *reference data only* — title, artist, catalog id — never audio. Real Apple
/// Music catalog search/playback activates once the MusicKit capability is enabled
/// on the App ID and a subscriber runs it on device (see AudioCoordinator).
enum SampleMusic {
    static let tracks: [TrackRefFfi] = [
        .init(catalogId: "1440857781", title: "Here Comes the Sun", artist: "The Beatles", artworkUrl: "", durationMs: 185_000),
        .init(catalogId: "1443109064", title: "Dreams", artist: "Fleetwood Mac", artworkUrl: "", durationMs: 257_000),
        .init(catalogId: "1452968391", title: "Sunflower", artist: "Post Malone, Swae Lee", artworkUrl: "", durationMs: 158_000),
        .init(catalogId: "1564530719", title: "good 4 u", artist: "Olivia Rodrigo", artworkUrl: "", durationMs: 178_000),
        .init(catalogId: "1490291913", title: "Watermelon Sugar", artist: "Harry Styles", artworkUrl: "", durationMs: 174_000),
        .init(catalogId: "1469577741", title: "Lovely Day", artist: "Bill Withers", artworkUrl: "", durationMs: 254_000),
    ]
}

/// Pick a song to play alongside a post.
struct MusicPickerView: View {
    var onPick: (TrackRefFfi) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                KithBackground()
                List {
                    Section {
                        ForEach(SampleMusic.tracks, id: \.catalogId) { t in
                            Button {
                                onPick(t)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "music.note")
                                        .foregroundStyle(.white)
                                        .frame(width: 40, height: 40)
                                        .background(KithTheme.brand, in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(t.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(KithTheme.pink)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    } footer: {
                        Text("Songs play through each person's own Apple Music subscription — Kith shares only the song's name, never the audio.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
