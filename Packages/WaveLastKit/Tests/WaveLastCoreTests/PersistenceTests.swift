// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing

@testable import WaveLastCore

@Suite("Persistence and migrations")
struct PersistenceTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID().uuidString).sqlite").path
    }

    @Test func freshDatabaseIsAtLatestSchema() throws {
        let store = try LibraryStore.inMemory()
        #expect(try store.db.userVersion == WaveLastSchema.migrator.latestVersion)
        #expect(WaveLastSchema.migrator.latestVersion == 2)
    }

    @Test func migratingV1DatabasePreservesData() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Build a version-1 database with data, as the first release would have.
        do {
            let db = try SQLiteDatabase(path: path)
            try WaveLastSchema.migrator.migrate(db, upTo: 1)
            #expect(try db.userVersion == 1)
            try db.execute(
                """
                INSERT INTO tracks (id, title, artist, album, duration, track_number, source, location, artwork_ref, added_at)
                VALUES ('t1', 'Old Song', 'Old Artist', '', 180, NULL, 'local', ?, NULL, 0)
                """, [try JSONEncoder().encode(TrackLocation.localFile(relativePath: "Music/t1.m4a"))])
            try db.execute("INSERT INTO playlists (id, name, created_at) VALUES ('p1', 'Mix', 0)")
            try db.execute("INSERT INTO playlist_items (playlist_id, position, track_id) VALUES ('p1', 0, 't1')")
            try db.execute("INSERT INTO podcast_progress (episode_key, position, updated_at) VALUES ('ep', 42, 0)")
            // v1 has no play_count column.
            #expect(throws: DatabaseError.self) { try db.query("SELECT play_count FROM tracks") }
        }
        // Opening the store migrates to v2.
        let store = try LibraryStore(database: SQLiteDatabase(path: path))
        #expect(try store.db.userVersion == 2)
        #expect(try store.track(id: "t1")?.title == "Old Song")
        #expect(try store.playlistTracks(id: "p1").map(\.id) == ["t1"])
        #expect(try store.playCount(trackID: "t1") == 0)
        let p = try store.progress(episodeKey: "ep")
        #expect(p?.position == 42)
        #expect(p?.completed == false)
    }

    @Test func refusesDatabaseFromNewerVersion() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("PRAGMA user_version = 99")
        #expect(throws: DatabaseError.newerSchema(found: 99, supported: 2)) {
            _ = try LibraryStore(database: db)
        }
    }

    @Test func failedMigrationRollsBack() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        let bad = Migrator([.init(1, ["CREATE TABLE a (x INTEGER)", "THIS IS NOT SQL"])])
        #expect(throws: DatabaseError.self) { try bad.migrate(db) }
        #expect(try db.userVersion == 0)
        #expect(throws: DatabaseError.self) { try db.query("SELECT * FROM a") }
    }

    @Test func tracksUpsertAndDelete() throws {
        let store = try LibraryStore.inMemory()
        try store.upsert([makeTrack(2), makeTrack(1)])
        var renamed = makeTrack(1)
        renamed.title = "Renamed"
        try store.upsert([renamed])
        #expect(try store.tracks().count == 2)
        #expect(try store.track(id: "t1")?.title == "Renamed")
        #expect(try store.track(id: "t1")?.location == .localFile(relativePath: "Music/t1.m4a"))
        try store.deleteTracks(ids: ["t2"])
        #expect(try store.tracks().map(\.id) == ["t1"])
    }

    @Test func playlistCreateAddReorderRenameDelete() throws {
        let store = try LibraryStore.inMemory()
        try store.upsert((1...3).map { makeTrack($0) })
        let p = try store.createPlaylist(name: "  Road Trip ")
        #expect(p.name == "Road Trip")
        try store.appendToPlaylist(id: p.id, trackIDs: ["t1", "t2"])
        try store.appendToPlaylist(id: p.id, trackIDs: ["t3", "t1"])
        #expect(try store.playlistTracks(id: p.id).map(\.id) == ["t1", "t2", "t3", "t1"], "duplicates allowed, order kept")
        try store.setPlaylistTracks(id: p.id, trackIDs: ["t3", "t2"])
        #expect(try store.playlistTracks(id: p.id).map(\.id) == ["t3", "t2"])
        try store.renamePlaylist(id: p.id, to: "Night Drive")
        try store.renamePlaylist(id: p.id, to: "   ")
        #expect(try store.playlists().first?.name == "Night Drive")
        #expect(try store.playlists().first?.trackCount == 2)
        try store.createPlaylist(name: "")
        #expect(try store.playlists().map(\.name) == ["New Playlist", "Night Drive"])
        try store.deletePlaylist(id: p.id)
        #expect(try store.playlists().count == 1)
    }

    @Test func deletingTrackRemovesItFromPlaylists() throws {
        let store = try LibraryStore.inMemory()
        try store.upsert([makeTrack(1), makeTrack(2)])
        let p = try store.createPlaylist(name: "P")
        try store.setPlaylistTracks(id: p.id, trackIDs: ["t1", "t2"])
        try store.deleteTracks(ids: ["t1"])
        #expect(try store.playlistTracks(id: p.id).map(\.id) == ["t2"])
    }

    @Test func historyIsNewestFirstCountsPlaysAndIsBounded() throws {
        let store = try LibraryStore.inMemory()
        try store.upsert([makeTrack(1), makeTrack(2)])
        try store.recordPlay(makeTrack(1), at: Date(timeIntervalSince1970: 10))
        try store.recordPlay(makeTrack(2), at: Date(timeIntervalSince1970: 20))
        try store.recordPlay(makeTrack(1), at: Date(timeIntervalSince1970: 30))
        #expect(try store.history().map(\.track.id) == ["t1", "t2", "t1"])
        #expect(try store.playCount(trackID: "t1") == 2)
        for i in 0..<1005 { try store.recordPlay(makeTrack(2), at: Date(timeIntervalSince1970: 100 + Double(i))) }
        #expect(try store.history(limit: 5000).count == 1000)
        try store.clearHistory()
        #expect(try store.history().isEmpty)
    }

    @Test func queueSnapshotSurvivesReopen() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var q = PlaybackQueue(tracks: (1...3).map { makeTrack($0) }, startAt: 1)
        q.repeatMode = .one
        try LibraryStore(database: SQLiteDatabase(path: path)).saveQueue(q, position: 42.5)

        let reopened = try LibraryStore(database: SQLiteDatabase(path: path))
        let loaded = try #require(try reopened.loadQueue())
        #expect(loaded.0 == q)
        #expect(loaded.1 == 42.5)
    }

    @Test func corruptQueueSnapshotIsIgnored() throws {
        let store = try LibraryStore.inMemory()
        try store.db.execute("INSERT INTO kv (key, value) VALUES ('queue', ?)", [Data("garbage".utf8)])
        #expect(try store.loadQueue() == nil)
    }

    @Test func podcastSubscriptionsAndProgress() throws {
        let store = try LibraryStore.inMemory()
        let feed = PodcastFeed(
            feedURL: URL(string: "https://e.com/f.xml")!, title: "Show", author: "A", summary: "",
            artworkURL: nil, episodes: [])
        try store.subscribe(feed)
        try store.subscribe(feed)
        #expect(try store.subscriptions().map(\.title) == ["Show"])
        try store.saveProgress(episodeKey: "ep1", position: 120)
        try store.saveProgress(episodeKey: "ep1", position: -5)
        #expect(try store.progress(episodeKey: "ep1")?.position == 0, "negative positions clamp to 0")
        try store.saveProgress(episodeKey: "ep1", position: 0, completed: true)
        #expect(try store.progress(episodeKey: "ep1")?.completed == true)
        #expect(try store.progress(episodeKey: "missing") == nil)
        try store.unsubscribe(feedURL: feed.feedURL)
        #expect(try store.subscriptions().isEmpty)
    }

    @Test func scrobbleBacklogIsFIFO() throws {
        let store = try LibraryStore.inMemory()
        for i in 0..<60 {
            try store.enqueueScrobble(ScrobbleEntry(artist: "a", track: "t\(i)", album: nil, duration: 100, timestamp: i))
        }
        let first = try store.pendingScrobbles(limit: 50)
        #expect(first.count == 50)
        #expect(first.first?.entry.track == "t0")
        try store.removeScrobbles(ids: first.map(\.id))
        #expect(try store.pendingScrobbles().map(\.entry.track) == (50..<60).map { "t\($0)" })
    }
}
