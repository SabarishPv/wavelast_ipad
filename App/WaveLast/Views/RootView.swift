// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import WaveLastCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case library, playlists, podcasts, discover, server, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .playlists: return "Playlists"
        case .podcasts: return "Podcasts"
        case .discover: return "Discover"
        case .server: return "Music Server"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "music.note.list"
        case .playlists: return "list.bullet.rectangle"
        case .podcasts: return "antenna.radiowaves.left.and.right"
        case .discover: return "sparkles"
        case .server: return "server.rack"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .library
    @State private var showNowPlaying = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    ForEach([SidebarItem.library, .playlists, .podcasts]) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                            .accessibilityIdentifier("sidebar.\(item.rawValue)")
                    }
                }
                Section("Online") {
                    ForEach([SidebarItem.discover, .server]) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                            .accessibilityIdentifier("sidebar.\(item.rawValue)")
                    }
                }
                Section {
                    ForEach([SidebarItem.history, .settings]) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                            .accessibilityIdentifier("sidebar.\(item.rawValue)")
                    }
                }
            }
            .navigationTitle("WaveLast")
        } detail: {
            NavigationStack {
                detail(for: selection ?? .library)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                StatusBanners()
                if model.player.currentTrack != nil {
                    MiniPlayerBar(showNowPlaying: $showNowPlaying)
                }
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .library: LibraryView()
        case .playlists: PlaylistsView()
        case .podcasts: PodcastsView()
        case .discover: DiscoverView()
        case .server: ServerView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

/// Offline indicator, transient confirmations and startup problems.
struct StatusBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.startupProblem {
                BannerView(text: problem, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if !model.isOnline {
                BannerView(
                    text: "Offline — your imported music still plays. Online features will resume when you reconnect.",
                    symbol: "wifi.slash", tint: .gray
                )
                .accessibilityIdentifier("banner.offline")
            }
            if let b = model.banner {
                BannerView(text: b, symbol: "checkmark.circle.fill", tint: Brand.accent)
                    .task(id: b) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if model.banner == b { model.banner = nil }
                    }
            }
        }
        .animation(.default, value: model.isOnline)
        .animation(.default, value: model.banner)
    }
}

struct BannerView: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }
}
