// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import WaveLastCore
import WaveLastPlayback

struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showNowPlaying: Bool

    var body: some View {
        let player = model.player
        HStack(spacing: 14) {
            Button {
                showNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: player.currentTrack, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.displayTitle ?? "").font(.headline).lineLimit(1)
                        Text(statusLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(player.currentTrack?.displayTitle ?? "")")
            .accessibilityHint("Opens the player")
            .accessibilityIdentifier("miniplayer.open")

            TransportButton(symbol: "backward.fill", label: "Previous track", size: 20) { player.previous() }
            TransportButton(
                symbol: player.isPlaying ? "pause.fill" : "play.fill",
                label: player.isPlaying ? "Pause" : "Play", size: 24
            ) {
                model.activateAudioIfNeeded()
                player.togglePlayPause()
            }
            .accessibilityIdentifier("miniplayer.playpause")
            TransportButton(symbol: "forward.fill", label: "Next track", size: 20) { player.next() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            GeometryReader { g in
                Rectangle().fill(Brand.accent)
                    .frame(width: g.size.width * progress, height: 2)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
    }

    private var progress: CGFloat {
        guard let d = model.player.duration, d > 0 else { return 0 }
        return CGFloat(min(1, max(0, model.player.elapsed / d)))
    }

    private var statusLine: String {
        switch model.player.status {
        case .loading: return "Loading…"
        case .buffering: return "Buffering…"
        case .failed(let f): return f.message
        default: return model.player.currentTrack?.displayArtist ?? ""
        }
    }
}

struct TransportButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .hoverEffect(.highlight)
    }
}

enum NowPlayingPanel: String, CaseIterable, Identifiable {
    case queue = "Up Next"
    case lyrics = "Lyrics"
    var id: String { rawValue }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var panel: NowPlayingPanel = .queue
    @State private var showPanelCompact = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = hSize == .regular && geo.size.width > geo.size.height * 1.1
                if wide {
                    HStack(spacing: 0) {
                        PlayerColumn(compact: false)
                            .frame(width: geo.size.width * 0.5)
                        Divider()
                        panelView.frame(maxWidth: .infinity)
                    }
                } else {
                    PlayerColumn(compact: true)
                        .sheet(isPresented: $showPanelCompact) {
                            NavigationStack {
                                panelView
                                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPanelCompact = false } } }
                            }
                            .presentationDetents([.medium, .large])
                        }
                        .toolbar {
                            ToolbarItemGroup(placement: .bottomBar) {
                                Button {
                                    panel = .queue; showPanelCompact = true
                                } label: {
                                    Label("Up Next", systemImage: "list.bullet")
                                }
                                .accessibilityIdentifier("nowplaying.showQueue")
                                Spacer()
                                Button {
                                    panel = .lyrics; showPanelCompact = true
                                } label: {
                                    Label("Lyrics", systemImage: "quote.bubble")
                                }
                                .accessibilityIdentifier("nowplaying.showLyrics")
                            }
                        }
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "chevron.down")
                    }
                    .accessibilityIdentifier("nowplaying.close")
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }

    private var panelView: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(NowPlayingPanel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("nowplaying.panelPicker")
            switch panel {
            case .queue: QueueView()
            case .lyrics: LyricsView()
            }
        }
    }
}

struct PlayerColumn: View {
    @Environment(AppModel.self) private var model
    let compact: Bool
    @State private var scrubbing: Double?

    var body: some View {
        let player = model.player
        ScrollView {
            VStack(spacing: 24) {
                ArtworkView(track: player.currentTrack, size: compact ? 300 : 360, cornerRadius: 20)
                    .shadow(radius: 18, y: 8)
                    .padding(.top, 24)

                VStack(spacing: 6) {
                    Text(player.currentTrack?.displayTitle ?? "Nothing playing")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("nowplaying.title")
                    Text(player.currentTrack?.displayArtist ?? "")
                        .font(.title3).foregroundStyle(.secondary)
                    if let album = player.currentTrack?.album, !album.isEmpty {
                        Text(album).font(.subheadline).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)

                timeline(player)

                if case .failed(let f) = player.status {
                    Label(f.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .accessibilityIdentifier("nowplaying.error")
                }

                HStack(spacing: 36) {
                    TransportButton(
                        symbol: player.queue.isShuffled ? "shuffle.circle.fill" : "shuffle",
                        label: player.queue.isShuffled ? "Shuffle on" : "Shuffle off", size: 22
                    ) {
                        player.setShuffle(!player.queue.isShuffled)
                    }
                    TransportButton(symbol: "backward.fill", label: "Previous track", size: 30) { player.previous() }
                    TransportButton(
                        symbol: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                        label: player.isPlaying ? "Pause" : "Play", size: 64
                    ) {
                        model.activateAudioIfNeeded()
                        player.togglePlayPause()
                    }
                    .accessibilityIdentifier("nowplaying.playpause")
                    TransportButton(symbol: "forward.fill", label: "Next track", size: 30) { player.next() }
                        .accessibilityIdentifier("nowplaying.next")
                    TransportButton(symbol: repeatSymbol(player.queue.repeatMode), label: repeatLabel(player.queue.repeatMode), size: 22) {
                        player.setRepeat(nextRepeat(player.queue.repeatMode))
                    }
                }
                .foregroundStyle(Brand.accent)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func timeline(_ player: PlaybackController) -> some View {
        let duration = max(player.duration ?? player.currentTrack?.duration ?? 0, 0)
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubbing ?? min(player.elapsed, duration) }, set: { scrubbing = $0 }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if !editing, let s = scrubbing {
                        player.seek(to: s)
                        scrubbing = nil
                    }
                }
            )
            .disabled(duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(scrubbing ?? player.elapsed)) of \(formatTime(duration))")
            .accessibilityIdentifier("nowplaying.timeline")
            HStack {
                Text(formatTime(scrubbing ?? player.elapsed))
                Spacer()
                Text(duration > 0 ? "-" + formatTime(max(0, duration - (scrubbing ?? player.elapsed))) : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 32)
    }

    private func repeatSymbol(_ m: RepeatMode) -> String { m == .one ? "repeat.1" : (m == .all ? "repeat.circle.fill" : "repeat") }
    private func repeatLabel(_ m: RepeatMode) -> String { m == .one ? "Repeat one" : (m == .all ? "Repeat all" : "Repeat off") }
    private func nextRepeat(_ m: RepeatMode) -> RepeatMode { m == .off ? .all : (m == .all ? .one : .off) }
}

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.queue.isEmpty {
            StateView(
                symbol: "list.bullet", title: "Queue is empty",
                message: "Play something from your library or add tracks with “Add to Queue”.")
        } else {
            List {
                ForEach(Array(player.queue.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 12) {
                        ArtworkView(track: entry.track, size: 40)
                        VStack(alignment: .leading) {
                            Text(entry.track.displayTitle)
                                .font(.body.weight(index == player.queue.currentIndex ? .semibold : .regular))
                                .foregroundStyle(index == player.queue.currentIndex ? Brand.accent : .primary)
                            Text(entry.track.displayArtist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if index == player.queue.currentIndex {
                            Image(systemName: "waveform").foregroundStyle(Brand.accent).accessibilityLabel("Current track")
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { player.select(entryID: entry.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Plays this track")
                    .accessibilityIdentifier("queue.row.\(index)")
                    .swipeActions {
                        Button(role: .destructive) {
                            player.removeFromQueue(ids: [entry.id])
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .onMove { player.moveInQueue(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    player.removeFromQueue(ids: Set(offsets.map { player.queue.entries[$0].id }))
                }
            }
            .listStyle(.plain)
            .toolbar { EditButton() }
            .accessibilityIdentifier("queue.list")
        }
    }
}

struct LyricsView: View {
    @Environment(AppModel.self) private var model
    @State private var result: LyricsLoadResult?
    @State private var loadedFor: String?

    var body: some View {
        let track = model.player.currentTrack
        Group {
            if track == nil {
                StateView(symbol: "quote.bubble", title: "No track", message: "Lyrics appear here while music plays.")
            } else if let result {
                switch result {
                case .found(.synced(let lines), let source):
                    SyncedLyrics(lines: lines, source: source)
                case .found(.plain(let text), let source):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(text).font(.title3).textSelection(.enabled)
                            SourceFooter(source: source, synced: false)
                        }
                        .padding(24)
                    }
                case .found(.instrumental, _):
                    StateView(symbol: "pianokeys", title: "Instrumental", message: "This track has no lyrics.")
                case .notFound:
                    StateView(
                        symbol: "text.page.slash", title: "No lyrics found",
                        message: "Import a matching .lrc file (named “Artist - Title.lrc”) from Files to add lyrics.")
                case .failed(let message):
                    StateView(
                        symbol: "wifi.exclamationmark", title: "Couldn't load lyrics", message: message,
                        actionTitle: "Try Again"
                    ) { Task { await load(force: true) } }
                }
            } else {
                ProgressView("Finding lyrics…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: track?.id) { await load(force: false) }
        .accessibilityIdentifier("lyrics.container")
    }

    private func load(force: Bool) async {
        guard let t = model.player.currentTrack else { return }
        if force { await model.lyrics.invalidate(trackID: t.id) }
        if loadedFor != t.id || force { result = nil }
        loadedFor = t.id
        let r = await model.lyrics.lyrics(for: t)
        if model.player.currentTrack?.id == t.id { result = r }
    }
}

struct SyncedLyrics: View {
    @Environment(AppModel.self) private var model
    let lines: [LyricLine]
    let source: LyricsSourceKind

    var body: some View {
        let active = Lyrics.activeLineIndex(in: lines, at: model.player.elapsed)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(line.index == active ? Color.primary : Color.secondary.opacity(0.55))
                            .scaleEffect(line.index == active ? 1.0 : 0.97, anchor: .leading)
                            .animation(.easeOut(duration: 0.25), value: active)
                            .id(line.index)
                            .onTapGesture { model.player.seek(to: line.time) }
                            .accessibilityAddTraits(
                                line.index == active ? AccessibilityTraits([.isSelected, .isButton]) : AccessibilityTraits.isButton
                            )
                            .accessibilityHint("Jumps to this line")
                            .accessibilityIdentifier("lyrics.line.\(line.index)")
                    }
                    SourceFooter(source: source, synced: true)
                }
                .padding(24)
            }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

struct SourceFooter: View {
    let source: LyricsSourceKind
    let synced: Bool
    var body: some View {
        Text("\(synced ? "Synced lyrics" : "Lyrics") from \(source.rawValue)")
            .font(.footnote).foregroundStyle(.tertiary)
            .padding(.top, 12)
    }
}
