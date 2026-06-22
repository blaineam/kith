import MediaPlayer
import MusicKit
import SwiftUI

/// Parse a track's encoded id "<storeID>~<persistentID>" (either part may be absent).
func trackIds(_ catalogId: String) -> (store: String?, pid: UInt64?) {
    let parts = catalogId.split(separator: "~", maxSplits: 1, omittingEmptySubsequences: false)
    let store = parts.first.map(String.init).flatMap { ($0.isEmpty || $0 == "0") ? nil : $0 }
    let pid = parts.count > 1 ? UInt64(parts[1]) : nil
    return (store, pid)
}

/// The exact library song matching a persistent id, if it exists on this device.
@MainActor func librarySong(_ pid: UInt64) -> MPMediaItem? {
    let q = MPMediaQuery.songs()
    q.addFilterPredicate(MPMediaPropertyPredicate(value: pid, forProperty: MPMediaItemPropertyPersistentID))
    return q.items?.first
}

/// An in-app song picker that lets you **hear** a song before choosing it, across two
/// sources you can toggle: **Your Library** (songs on this device) and **Apple Music**
/// (the full catalog, searched live via MusicKit). Either way we keep only a `TrackRef`
/// (the ids + title/artist) — never the audio. Each viewer plays it through their own
/// Apple Music, so Haven shares the *reference*, not the file.
struct SongPicker: View {
    var onPick: (TrackRefFfi) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable { case library = "Your Library", catalog = "Apple Music" }
    @State private var source: Source = .library
    @State private var query = ""
    @State private var previewing: String?          // unified key: persistentID or catalog id
    @State private var libraryDenied = false
    @State private var songs: [MPMediaItem] = []
    @State private var catalog: [MusicKit.Song] = []
    @State private var catalogNote: String?
    @State private var searchTask: Task<Void, Never>?
    private let preview = MPMusicPlayerController.applicationMusicPlayer

    private var filteredLibrary: [MPMediaItem] {
        guard !query.isEmpty else { return songs }
        return songs.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.artist ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                VStack(spacing: 0) {
                    Picker("", selection: $source) {
                        ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.top, 8)

                    if source == .library { libraryList } else { catalogList }
                }
            }
            .navigationTitle("Pick a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { stopPreview(); dismiss() } } }
            .searchable(text: $query, prompt: source == .library ? "Search your music" : "Search Apple Music")
            .onAppear(perform: loadLibrary)
            .onDisappear(perform: stopPreview)
            .onChange(of: source) { _, s in
                stopPreview()
                if s == .catalog && !query.isEmpty { scheduleCatalogSearch() }
            }
            .onChange(of: query) { _, _ in if source == .catalog { scheduleCatalogSearch() } }
        }
    }

    // MARK: - Library

    @ViewBuilder private var libraryList: some View {
        if libraryDenied {
            ContentUnavailableView("Music access off", systemImage: "music.note.list",
                                   description: Text("Allow access to your music in Settings to pick a song."))
        } else {
            List(filteredLibrary, id: \.persistentID) { item in
                songRow(title: item.title ?? "Unknown song", artist: item.artist ?? "", key: "\(item.persistentID)",
                        onPreview: { togglePreviewLibrary(item) }, onUse: { chooseLibrary(item) })
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Apple Music catalog

    @ViewBuilder private var catalogList: some View {
        if let note = catalogNote {
            ContentUnavailableView("Apple Music", systemImage: "music.note", description: Text(note))
        } else if catalog.isEmpty {
            ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass",
                                   description: Text("Find any song in the catalog."))
        } else {
            List(catalog, id: \.id) { song in
                songRow(title: song.title, artist: song.artistName, key: song.id.rawValue,
                        onPreview: { togglePreviewCatalog(song) }, onUse: { chooseCatalog(song) })
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func songRow(title: String, artist: String, key: String,
                         onPreview: @escaping () -> Void, onUse: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                Image(systemName: previewing == key ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2).foregroundStyle(HavenTheme.pink)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Use", action: onUse)
                .font(.subheadline.weight(.semibold)).tint(HavenTheme.pink).buttonStyle(.bordered)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Loading + search

    private func loadLibrary() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { libraryDenied = true; return }
                songs = (MPMediaQuery.songs().items ?? []).sorted { ($0.title ?? "") < ($1.title ?? "") }
            }
        }
    }

    private func scheduleCatalogSearch() {
        searchTask?.cancel()
        let term = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)   // debounce keystrokes
            if Task.isCancelled { return }
            await runCatalogSearch(term)
        }
    }

    private func runCatalogSearch(_ term: String) async {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { catalog = []; catalogNote = nil; return }
        let status = await MusicAuthorization.request()
        guard status == .authorized else { catalogNote = "Allow Apple Music access to search the catalog."; return }
        do {
            var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            req.limit = 25
            let res = try await req.response()
            catalog = Array(res.songs)
            catalogNote = catalog.isEmpty ? "No songs found." : nil
        } catch {
            catalogNote = "Couldn't reach Apple Music — check your connection or subscription."
        }
    }

    // MARK: - Preview + choose

    private func togglePreviewLibrary(_ item: MPMediaItem) {
        let key = "\(item.persistentID)"
        if previewing == key { stopPreview() }
        else { preview.setQueue(with: MPMediaItemCollection(items: [item])); preview.play(); previewing = key }
    }
    private func togglePreviewCatalog(_ song: MusicKit.Song) {
        let key = song.id.rawValue
        if previewing == key { stopPreview() }
        else { preview.setQueue(with: [key]); preview.play(); previewing = key }
    }
    private func stopPreview() {
        if previewing != nil { preview.stop() }
        previewing = nil
    }

    private func chooseLibrary(_ item: MPMediaItem) {
        stopPreview()
        onPick(TrackRefFfi(
            catalogId: "\(item.playbackStoreID)~\(item.persistentID)",
            title: item.title ?? "Unknown song",
            artist: item.artist ?? "",
            artworkUrl: "",
            durationMs: UInt64(max(0, item.playbackDuration) * 1000)
        ))
        dismiss()
    }
    private func chooseCatalog(_ song: MusicKit.Song) {
        stopPreview()
        // Catalog songs have no local persistent id — encode just the store id ("<id>~").
        onPick(TrackRefFfi(
            catalogId: "\(song.id.rawValue)~",
            title: song.title,
            artist: song.artistName,
            artworkUrl: "",
            durationMs: UInt64((song.duration ?? 0) * 1000)
        ))
        dismiss()
    }
}
