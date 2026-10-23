// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import WaveLastCore

/// Last.fm-powered suggestions. WaveLast has no catalogue of its own, so a
/// suggestion is playable only if it is in the library or on the user's
/// music server; otherwise it links to Last.fm.
struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var recs: [Recommendation] = []
    @State private var loading = false
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.lastFMUser == nil {
                StateView(
                    symbol: "sparkles", title: "Connect Last.fm",
                    message: "Recommendations come from your Last.fm listening history. Connect your account in Settings.")
            } else if !model.isOnline && recs.isEmpty {
                StateView(symbol: "wifi.slash", title: "You're offline", message: "Recommendations need an internet connection.")
            } else if let error, recs.isEmpty {
                StateView(
                    symbol: "exclamationmark.triangle", title: "Couldn't load recommendations", message: error,
                    actionTitle: "Try Again"
                ) { Task { await load() } }
            } else if loading && recs.isEmpty {
                ProgressView("Finding music you might like…")
            } else if recs.isEmpty {
                StateView(symbol: "sparkles", title: "Nothing yet", message: "Play and scrobble a few songs, then pull to refresh.")
            } else {
                List(recs) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.title).font(.body)
                            Text(r.artist).font(.subheadline).foregroundStyle(.secondary)
                            Text("Because you played \(r.becauseOf.prefix(2).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let match = localMatch(r) {
                            Button {
                                model.play([match])
                            } label: {
                                Label("Play", systemImage: "play.circle.fill").labelStyle(.iconOnly).font(.title2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play \(r.title)")
                        } else {
                            Button {
                                if let url = lastFMURL(r) { openURL(url) }
                            } label: {
                                Image(systemName: "arrow.up.right.square").font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(r.title) on Last.fm")
                        }
                    }
                    .frame(minHeight: 44)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Discover")
        .refreshable { await load() }
        .task { if recs.isEmpty { await load() } }
    }

    private func localMatch(_ r: Recommendation) -> Track? {
        model.tracks.first {
            RecommendationRanker.key(artist: $0.artist, title: $0.title) == RecommendationRanker.key(artist: r.artist, title: r.title)
        }
    }

    private func lastFMURL(_ r: Recommendation) -> URL? {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?.replacingOccurrences(of: "/", with: "%2F") ?? s
        }
        return URL(string: "https://www.last.fm/music/\(enc(r.artist))/_/\(enc(r.title))")
    }

    private func load() async {
        guard let c = model.lastFMCredentials(), model.lastFMSession() != nil else { return }
        loading = true
        defer { loading = false }
        error = nil
        let client = LastFMClient(credentials: c)
        // Seeds: the most recently played distinct tracks.
        var seen = Set<String>()
        let seeds = ((try? model.store.history(limit: 100)) ?? []).map(\.track).filter {
            $0.source != .podcast && seen.insert(RecommendationRanker.key(artist: $0.artist, title: $0.title)).inserted
        }.prefix(5)
        guard !seeds.isEmpty else { recs = []; return }
        var results: [(seed: String, similar: [LastFMSimilarTrack])] = []
        var lastError: Error?
        for s in seeds {
            do {
                let similar = try await client.similarTracks(artist: s.artist, track: s.title, limit: 20)
                results.append((s.displayTitle, similar))
            } catch { lastError = error }
        }
        let known = Set(seeds.map { RecommendationRanker.key(artist: $0.artist, title: $0.title) })
        recs = RecommendationRanker.rank(similarBySeed: results, exclude: known)
        if results.isEmpty, let lastError {
            error = (lastError as? NetworkError)?.userMessage ?? (lastError as? LastFMAPIError)?.message ?? lastError.localizedDescription
        }
    }
}

/// Search and stream from the user's own Subsonic-compatible server.
struct ServerView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        Group {
            if !model.subsonicConfigured {
                StateView(
                    symbol: "server.rack", title: "No music server",
                    message:
                        "Stream your own collection from Navidrome, Airsonic, Gonic or another Subsonic-compatible server you run or have an account on. Add it in Settings."
                )
            } else if !model.isOnline {
                StateView(symbol: "wifi.slash", title: "You're offline", message: "Your music server needs a network connection.")
            } else if let error {
                StateView(symbol: "exclamationmark.triangle", title: "Search failed", message: error)
            } else if results.isEmpty {
                StateView(
                    symbol: "magnifyingglass", title: query.isEmpty ? "Search your server" : "No results",
                    message: query.isEmpty ? "Type to search songs on your music server." : "Try a different search.")
            } else {
                List(Array(results.enumerated()), id: \.element.id) { index, t in
                    TrackRow(track: t) { model.play(results, startAt: index) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Music Server")
        .searchable(text: $query, prompt: "Search your server")
        .onSubmit(of: .search) { Task { await search() } }
        .toolbar { if searching { ProgressView() } }
    }

    private func search() async {
        guard let client = model.subsonicClient(), !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        defer { searching = false }
        error = nil
        do {
            results = try await client.search(query)
        } catch let e as SubsonicAPIError {
            error = e.isAuthenticationError ? "The server rejected your username or password." : e.message
        } catch let e as NetworkError {
            error = e.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}
