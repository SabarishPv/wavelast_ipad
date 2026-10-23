// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import UIKit
import WaveLastCore

/// Square artwork with a generated placeholder when there is none.
struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let track: Track?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let track, let url = model.artworkURL(for: track) {
                if url.isFileURL {
                    if let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                } else {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Brand.gradient
            Image(systemName: track?.source == .podcast ? "mic.fill" : "music.note")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// A tappable track row with the standard queue/playlist context menu.
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    var subtitle: String?
    var onPlay: () -> Void

    var isCurrent: Bool { model.player.currentTrack?.id == track.id }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Brand.accent : .primary)
                        .lineLimit(1)
                    Text(subtitle ?? track.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isCurrent && model.player.isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Brand.accent)
                        .accessibilityLabel("Now playing")
                }
                if let d = track.duration {
                    Text(formatTime(d)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.displayTitle), \(track.displayArtist)")
        .accessibilityHint("Plays this track")
        .accessibilityIdentifier("track.\(track.title)")
        .contextMenu { TrackMenu(tracks: [track]) }
    }
}

/// Queue and playlist actions shared by context menus and swipe actions.
struct TrackMenu: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        Button {
            model.activateAudioIfNeeded()
            model.player.playNext(tracks)
            model.banner = "Playing next"
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            model.activateAudioIfNeeded()
            model.player.addToQueue(tracks)
            model.banner = "Added to queue"
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
        if !model.playlists.isEmpty {
            Menu {
                ForEach(model.playlists) { p in
                    Button(p.name) { model.add(tracks, to: p) }
                }
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
        }
    }
}

/// Empty / error / permission states with an optional action.
struct StateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "--:--" }
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
