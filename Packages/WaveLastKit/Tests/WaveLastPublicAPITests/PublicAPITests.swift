// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing
import WaveLastCore
import WaveLastPlayback

/// Compile-time check that every type and member the app uses is public.
/// Mirrors how App/WaveLast constructs and calls into the package.
@Suite("Public API used by the app")
struct PublicAPITests {
    @Test func coreTypesAreConstructibleFromOutsideTheModule() throws {
        let session = LastFMSession(username: "u", key: "k")
        let creds = LastFMCredentials(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32))
        let client = LastFMClient(credentials: creds)
        #expect(client.authorizationURL(token: "t").absoluteString.contains("token=t"))
        #expect(session.username == "u")

        let sub = SubsonicConfiguration(serverURL: URL(string: "https://example.com")!, username: "u", password: "p")
        let subClient = SubsonicClient(config: sub)
        _ = subClient.coverArtURL(id: "x")
        var registry = SourceRegistry([PodcastSource(), LocalFileSource(libraryRoot: URL(fileURLWithPath: "/tmp"))])
        registry.register(SubsonicSource(client: subClient))
        #expect(registry.provider(for: .subsonic) != nil)
        registry.unregister(.subsonic)

        let track = Track(
            id: "1", title: "t", artist: "a", album: "", duration: 1, source: .local,
            location: .localFile(relativePath: "x"))
        _ = ScrobbleEntry(artist: track.displayArtist, track: track.displayTitle, album: nil, duration: nil, timestamp: 0)
        _ = PlayableItem(url: URL(fileURLWithPath: "/tmp/x"))
        _ = RecommendationRanker.rank(similarBySeed: [], exclude: [])
        _ = RecommendationRanker.key(artist: "a", title: "b")
        _ = LRCLIBClient()
        _ = PodcastFeedLoader()
        _ = NetworkError.offline.userMessage
        _ = WaveLastInfo.sourceURL

        let store = try LibraryStore.inMemory()
        try store.upsert([track])
        _ = try store.history()
        _ = try store.playlists()
        _ = try store.subscriptions()
        _ = try store.progress(episodeKey: "x")
    }

    @MainActor
    @Test func playbackTypesAreUsableFromOutsideTheModule() async {
        let importer = LocalImporter(libraryRoot: URL(fileURLWithPath: "/tmp/wl-api"))
        _ = importer.musicFolder
        _ = LocalImporter.lyricsKey(for: Track(id: "1", title: "t", artist: "a", source: .local, location: .localFile(relativePath: "x")))
        _ = SupportedAudioFormats.contentTypes
        let lyrics = LyricsService(lyricsFolder: importer.lyricsFolder, lrclib: nil)
        await lyrics.invalidate(trackID: "1")

        let player = PlaybackController(engine: AVPlayerEngine(), sources: SourceRegistry(), store: nil)
        _ = player.queue.entries
        _ = player.handleRemote(.play)
        player.handleAudioSession(.interruptionBegan)
        player.sources.register(PodcastSource())

        let np = NowPlayingController()
        np.bind { _ in true }
        np.unbind()
        _ = BackgroundAudioConfiguration.validate(infoDictionary: nil)
    }
}
