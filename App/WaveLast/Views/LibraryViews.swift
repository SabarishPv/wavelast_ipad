// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import WaveLastCore
import WaveLastPlayback

enum LibrarySort: String, CaseIterable, Identifiable {
    case artist = "Artist", title = "Title", recent = "Recently Added"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showImporter = false
    @State private var sort: LibrarySort = .artist
    @State private var importError: String?

    var filtered: [Track] {
        let local = model.tracks.filter { $0.source == .local }
        let matched =
            query.isEmpty
            ? local
            : local.filter {
                TextMatch.matches(query: query, in: "\($0.title) \($0.artist) \($0.album)")
            }
        switch sort {
        case .artist: return matched
        case .title: return matched.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent: return matched.reversed()
        }
    }

    var body: some View {
        let tracks = filtered
        Group {
            if model.tracks.filter({ $0.source == .local }).isEmpty {
                StateView(
                    symbol: "square.and.arrow.down", title: "Your library is empty",
                    message:
                        "Import music from the Files app: MP3, AAC/M4A, ALAC, FLAC, WAV and AIFF are supported. Add matching .lrc files for synced lyrics.",
                    actionTitle: "Import Music"
                ) { showImporter = true }
                .accessibilityIdentifier("library.empty")
            } else if tracks.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track) { model.play(tracks, startAt: index) }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        model.player.playNext([track])
                                    } label: {
                                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    .tint(Brand.accent)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        model.delete([track])
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("library.list")
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Songs, artists, albums")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isImporting { ProgressView() }
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    model.play(tracks.shuffled())
                } label: {
                    Label("Shuffle All", systemImage: "shuffle")
                }
                .disabled(tracks.isEmpty)
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: [.command])
                .accessibilityIdentifier("library.import")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: SupportedAudioFormats.contentTypes, allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Import finished", isPresented: Binding(get: { model.lastImport != nil }, set: { if !$0 { model.lastImport = nil } })) {
            Button("OK") { model.lastImport = nil }
        } message: {
            Text(importSummary(model.lastImport))
        }
        .alert("Couldn't open Files", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text((importError ?? "") + "\nIf you denied access to a location, allow it in the Files app and try again.")
        }
    }

    private func importSummary(_ r: ImportResult?) -> String {
        guard let r else { return "" }
        var parts = ["Imported \(r.imported.count) song\(r.imported.count == 1 ? "" : "s")."]
        if !r.lyricsFiles.isEmpty { parts.append("Added \(r.lyricsFiles.count) lyrics file(s).") }
        if !r.duplicates.isEmpty { parts.append("Skipped \(r.duplicates.count) already in your library.") }
        if !r.unsupported.isEmpty {
            parts.append("Unsupported format: \(r.unsupported.joined(separator: ", ")). Ogg/Opus/WMA can't be played by iPadOS.")
        }
        if !r.failed.isEmpty { parts.append("Failed: " + r.failed.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; ")) }
        return parts.joined(separator: "\n")
    }
}

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                StateView(
                    symbol: "music.note.list", title: "No playlists yet",
                    message: "Create a playlist, then add songs from any track's menu.",
                    actionTitle: "New Playlist"
                ) { showNew = true }
            } else {
                List {
                    ForEach(model.playlists) { p in
                        NavigationLink(value: p) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(p.name)
                                    Text("\(p.trackCount) song\(p.trackCount == 1 ? "" : "s")").font(.subheadline).foregroundStyle(
                                        .secondary)
                                }
                            } icon: {
                                Image(systemName: "music.note.list")
                            }
                        }
                        .accessibilityIdentifier("playlist.\(p.name)")
                    }
                    .onDelete { offsets in
                        for i in offsets { try? model.store.deletePlaylist(id: model.playlists[i].id) }
                        model.reload()
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        .toolbar {
            Button {
                showNew = true
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
            .accessibilityIdentifier("playlists.new")
        }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") {
                model.createPlaylist(named: newName); newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        Group {
            if tracks.isEmpty {
                StateView(symbol: "music.note", title: "Empty playlist", message: "Use “Add to Playlist” on any song to fill it.")
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track) { model.play(tracks, startAt: index) }
                    }
                    .onMove { from, to in
                        tracks.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                    .onDelete { offsets in
                        tracks.remove(atOffsets: offsets)
                        save()
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.play(tracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }.disabled(tracks.isEmpty)
                Button {
                    model.play(tracks.shuffled())
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }.disabled(tracks.isEmpty)
                Button {
                    name = playlist.name; renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                EditButton()
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") {
                try? model.store.renamePlaylist(id: playlist.id, to: name); model.reload()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { tracks = (try? model.store.playlistTracks(id: playlist.id)) ?? [] }
    }

    private func save() {
        try? model.store.setPlaylistTracks(id: playlist.id, trackIDs: tracks.map(\.id))
        model.reload()
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [HistoryItem] = []

    var body: some View {
        Group {
            if items.isEmpty {
                StateView(symbol: "clock", title: "No history yet", message: "Songs and episodes you play appear here.")
            } else {
                List(items) { item in
                    TrackRow(
                        track: item.track,
                        subtitle: "\(item.track.displayArtist) · \(item.playedAt.formatted(.relative(presentation: .named)))"
                    ) {
                        model.play([item.track])
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button("Clear", role: .destructive) {
                try? model.store.clearHistory(); items = []
            }.disabled(items.isEmpty)
        }
        .task(id: model.player.currentTrack?.id) { items = (try? model.store.history()) ?? [] }
    }
}

struct PodcastsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var feedText = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        Group {
            if model.subscriptions.isEmpty {
                StateView(
                    symbol: "antenna.radiowaves.left.and.right", title: "No podcasts",
                    message: "Subscribe by pasting a podcast's RSS feed URL.", actionTitle: "Add Podcast"
                ) { showAdd = true }
            } else {
                List {
                    ForEach(model.subscriptions) { s in
                        NavigationLink(value: s) {
                            VStack(alignment: .leading) {
                                Text(s.title)
                                if !s.author.isEmpty { Text(s.author).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? model.store.unsubscribe(feedURL: model.subscriptions[i].feedURL) }
                        model.reload()
                    }
                }
            }
        }
        .navigationTitle("Podcasts")
        .navigationDestination(for: PodcastSubscription.self) { PodcastDetailView(subscription: $0) }
        .toolbar {
            if adding { ProgressView() }
            Button {
                showAdd = true
            } label: {
                Label("Add Podcast", systemImage: "plus")
            }
        }
        .alert("Add Podcast", isPresented: $showAdd) {
            TextField("https://example.com/feed.xml", text: $feedText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Subscribe") { Task { await add() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the RSS feed address.")
        }
        .alert("Couldn't add podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func add() async {
        let text = feedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            error = "That isn't a valid web address."
            return
        }
        guard model.isOnline else { error = NetworkError.offline.userMessage; return }
        adding = true
        defer { adding = false }
        do {
            let feed = try await model.podcastLoader.load(url)
            try model.store.subscribe(feed)
            feedText = ""
            model.reload()
        } catch let e as NetworkError {
            error = e.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PodcastDetailView: View {
    @Environment(AppModel.self) private var model
    let subscription: PodcastSubscription
    @State private var feed: PodcastFeed?
    @State private var error: String?

    var body: some View {
        Group {
            if let feed {
                List(feed.episodes) { ep in
                    let track = ep.track(in: feed)
                    let progress = try? model.store.progress(episodeKey: track.id)
                    TrackRow(track: track, subtitle: episodeSubtitle(ep, progress: progress)) {
                        model.play([track])
                    }
                }
                .listStyle(.inset)
                .refreshable { await load() }
            } else if let error {
                StateView(
                    symbol: model.isOnline ? "exclamationmark.triangle" : "wifi.slash", title: "Couldn't load episodes",
                    message: error, actionTitle: "Try Again"
                ) { Task { await load() } }
            } else {
                ProgressView("Loading episodes…")
            }
        }
        .navigationTitle(subscription.title)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            let f = try await model.podcastLoader.load(subscription.feedURL)
            feed = f
            try? model.store.subscribe(f)
        } catch let e as NetworkError {
            error = e.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func episodeSubtitle(_ ep: PodcastEpisode, progress: (position: TimeInterval, completed: Bool)?) -> String {
        var parts: [String] = []
        if let d = ep.publishedAt { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        if let p = progress {
            if p.completed { parts.append("Played") } else if p.position > 5 { parts.append("Resume at \(formatTime(p.position))") }
        }
        return parts.isEmpty ? ep.title : parts.joined(separator: " · ")
    }
}
