// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

public struct Playlist: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var trackCount: Int
}

public struct HistoryItem: Equatable, Sendable, Identifiable {
    public var id: Int
    public var track: Track
    public var playedAt: Date
}

public struct PodcastSubscription: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { feedURL.absoluteString }
    public var feedURL: URL
    public var title: String
    public var author: String
    public var artworkURL: URL?
    public var lastRefreshed: Date?
}

/// WaveLast's schema. Version 1 is the first release; version 2 adds play
/// counts and podcast completion so the migration path is exercised from day one.
public enum WaveLastSchema {
    public static let migrator = Migrator([
        .init(
            1,
            [
                """
                CREATE TABLE tracks (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL DEFAULT '',
                    album TEXT NOT NULL DEFAULT '',
                    duration REAL,
                    track_number INTEGER,
                    source TEXT NOT NULL,
                    location TEXT NOT NULL,
                    artwork_ref TEXT,
                    added_at REAL NOT NULL
                )
                """,
                "CREATE INDEX tracks_source ON tracks(source)",
                """
                CREATE TABLE playlists (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE playlist_items (
                    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    PRIMARY KEY (playlist_id, position)
                )
                """,
                """
                CREATE TABLE history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    track_json BLOB NOT NULL,
                    played_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE podcasts (
                    feed_url TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    author TEXT NOT NULL DEFAULT '',
                    artwork_url TEXT,
                    last_refreshed REAL
                )
                """,
                """
                CREATE TABLE podcast_progress (
                    episode_key TEXT PRIMARY KEY,
                    position REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """,
                "CREATE TABLE kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
                """
                CREATE TABLE scrobble_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entry_json BLOB NOT NULL
                )
                """,
            ]),
        .init(
            2,
            [
                "ALTER TABLE tracks ADD COLUMN play_count INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE podcast_progress ADD COLUMN completed INTEGER NOT NULL DEFAULT 0",
            ]),
    ])
}

/// All persisted app data. Synchronous API over a serialised SQLite handle;
/// call from a background task for large batches.
public final class LibraryStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: SQLiteDatabase) throws {
        db = database
        try WaveLastSchema.migrator.migrate(db)
    }

    public static func inMemory() throws -> LibraryStore {
        try LibraryStore(database: SQLiteDatabase(path: ":memory:"))
    }

    // MARK: Tracks

    public func upsert(_ tracks: [Track], addedAt: Date = Date()) throws {
        try db.transaction { tx in
            for t in tracks {
                try tx.execute(
                    """
                    INSERT INTO tracks (id, title, artist, album, duration, track_number, source, location, artwork_ref, added_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=excluded.album,
                      duration=excluded.duration, track_number=excluded.track_number, location=excluded.location,
                      artwork_ref=excluded.artwork_ref
                    """,
                    [
                        t.id, t.title, t.artist, t.album, t.duration, t.trackNumber, t.source.rawValue,
                        try encoder.encode(t.location), t.artworkRef, addedAt.timeIntervalSince1970,
                    ])
            }
        }
    }

    public func tracks(source: SourceID? = nil) throws -> [Track] {
        let rows =
            try source.map {
                try db.query(
                    "SELECT * FROM tracks WHERE source = ? ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE, track_number, title COLLATE NOCASE",
                    [$0.rawValue])
            } ?? db.query("SELECT * FROM tracks ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE, track_number, title COLLATE NOCASE")
        return rows.compactMap(track(from:))
    }

    public func track(id: String) throws -> Track? {
        try db.query("SELECT * FROM tracks WHERE id = ?", [id]).first.flatMap(track(from:))
    }

    public func deleteTracks(ids: [String]) throws {
        try db.transaction { tx in
            for id in ids { try tx.execute("DELETE FROM tracks WHERE id = ?", [id]) }
        }
    }

    public func incrementPlayCount(trackID: String) throws {
        try db.execute("UPDATE tracks SET play_count = play_count + 1 WHERE id = ?", [trackID])
    }

    public func playCount(trackID: String) throws -> Int {
        try db.query("SELECT play_count FROM tracks WHERE id = ?", [trackID]).first?.int("play_count") ?? 0
    }

    private func track(from r: SQLRow) -> Track? {
        guard let id = r.string("id"), let title = r.string("title"), let src = r.string("source"),
            let locData = r.data("location"), let loc = try? decoder.decode(TrackLocation.self, from: locData)
        else { return nil }
        return Track(
            id: id, title: title, artist: r.string("artist") ?? "", album: r.string("album") ?? "",
            duration: r.double("duration"), trackNumber: r.int("track_number"),
            source: SourceID(rawValue: src), location: loc, artworkRef: r.string("artwork_ref"))
    }

    // MARK: Playlists

    @discardableResult
    public func createPlaylist(name: String, id: String = UUID().uuidString, at date: Date = Date()) throws -> Playlist {
        let clean = name.trimmed.isEmpty ? "New Playlist" : name.trimmed
        try db.execute("INSERT INTO playlists (id, name, created_at) VALUES (?, ?, ?)", [id, clean, date.timeIntervalSince1970])
        return Playlist(id: id, name: clean, createdAt: date, trackCount: 0)
    }

    public func renamePlaylist(id: String, to name: String) throws {
        guard !name.trimmed.isEmpty else { return }
        try db.execute("UPDATE playlists SET name = ? WHERE id = ?", [name.trimmed, id])
    }

    public func deletePlaylist(id: String) throws {
        try db.execute("DELETE FROM playlists WHERE id = ?", [id])
    }

    public func playlists() throws -> [Playlist] {
        try db.query(
            """
            SELECT p.id, p.name, p.created_at, COUNT(i.track_id) AS n
            FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id
            GROUP BY p.id ORDER BY p.name COLLATE NOCASE
            """
        ).compactMap { r in
            guard let id = r.string("id"), let name = r.string("name") else { return nil }
            return Playlist(
                id: id, name: name, createdAt: Date(timeIntervalSince1970: r.double("created_at") ?? 0), trackCount: r.int("n") ?? 0)
        }
    }

    public func playlistTracks(id: String) throws -> [Track] {
        try db.query(
            """
            SELECT t.* FROM playlist_items i JOIN tracks t ON t.id = i.track_id
            WHERE i.playlist_id = ? ORDER BY i.position
            """, [id]
        ).compactMap(track(from:))
    }

    /// Replaces the playlist's contents (used for add, remove and reorder so
    /// positions are always dense 0..n-1).
    public func setPlaylistTracks(id: String, trackIDs: [String]) throws {
        try db.transaction { tx in
            try tx.execute("DELETE FROM playlist_items WHERE playlist_id = ?", [id])
            for (pos, tid) in trackIDs.enumerated() {
                try tx.execute("INSERT INTO playlist_items (playlist_id, position, track_id) VALUES (?, ?, ?)", [id, pos, tid])
            }
        }
    }

    public func appendToPlaylist(id: String, trackIDs: [String]) throws {
        let existing = try playlistTracks(id: id).map(\.id)
        try setPlaylistTracks(id: id, trackIDs: existing + trackIDs)
    }

    // MARK: History

    public func recordPlay(_ track: Track, at date: Date = Date()) throws {
        try db.execute(
            "INSERT INTO history (track_json, played_at) VALUES (?, ?)", [try encoder.encode(track), date.timeIntervalSince1970])
        try incrementPlayCount(trackID: track.id)
        // Keep history bounded.
        try db.execute("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY played_at DESC, id DESC LIMIT 1000)")
    }

    public func history(limit: Int = 200) throws -> [HistoryItem] {
        try db.query("SELECT * FROM history ORDER BY played_at DESC, id DESC LIMIT ?", [limit]).compactMap { r in
            guard let id = r.int("id"), let data = r.data("track_json"),
                let t = try? decoder.decode(Track.self, from: data)
            else { return nil }
            return HistoryItem(id: id, track: t, playedAt: Date(timeIntervalSince1970: r.double("played_at") ?? 0))
        }
    }

    public func clearHistory() throws { try db.execute("DELETE FROM history") }

    // MARK: Queue snapshot

    public func saveQueue(_ queue: PlaybackQueue, position: TimeInterval) throws {
        let snap = QueueSnapshot(queue: queue, position: position)
        try db.execute("INSERT OR REPLACE INTO kv (key, value) VALUES ('queue', ?)", [try encoder.encode(snap)])
    }

    public func loadQueue() throws -> (PlaybackQueue, TimeInterval)? {
        guard let data = try db.query("SELECT value FROM kv WHERE key = 'queue'").first?.data("value") else { return nil }
        // A snapshot from an incompatible build is discarded rather than crashing.
        guard let snap = try? decoder.decode(QueueSnapshot.self, from: data) else { return nil }
        return (snap.queue, snap.position)
    }

    struct QueueSnapshot: Codable {
        var queue: PlaybackQueue
        var position: TimeInterval
    }

    // MARK: Podcasts

    public func subscribe(_ feed: PodcastFeed, at date: Date = Date()) throws {
        try db.execute(
            """
            INSERT INTO podcasts (feed_url, title, author, artwork_url, last_refreshed) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(feed_url) DO UPDATE SET title=excluded.title, author=excluded.author,
              artwork_url=excluded.artwork_url, last_refreshed=excluded.last_refreshed
            """, [feed.feedURL.absoluteString, feed.title, feed.author, feed.artworkURL?.absoluteString, date.timeIntervalSince1970])
    }

    public func unsubscribe(feedURL: URL) throws {
        try db.execute("DELETE FROM podcasts WHERE feed_url = ?", [feedURL.absoluteString])
    }

    public func subscriptions() throws -> [PodcastSubscription] {
        try db.query("SELECT * FROM podcasts ORDER BY title COLLATE NOCASE").compactMap { r in
            guard let u = r.string("feed_url").flatMap(URL.init(string:)) else { return nil }
            return PodcastSubscription(
                feedURL: u, title: r.string("title") ?? "", author: r.string("author") ?? "",
                artworkURL: r.string("artwork_url").flatMap(URL.init(string:)),
                lastRefreshed: r.double("last_refreshed").map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func saveProgress(episodeKey: String, position: TimeInterval, completed: Bool = false, at date: Date = Date()) throws {
        try db.execute(
            """
            INSERT INTO podcast_progress (episode_key, position, updated_at, completed) VALUES (?, ?, ?, ?)
            ON CONFLICT(episode_key) DO UPDATE SET position=excluded.position, updated_at=excluded.updated_at, completed=excluded.completed
            """, [episodeKey, max(0, position), date.timeIntervalSince1970, completed])
    }

    public func progress(episodeKey: String) throws -> (position: TimeInterval, completed: Bool)? {
        guard let r = try db.query("SELECT position, completed FROM podcast_progress WHERE episode_key = ?", [episodeKey]).first else {
            return nil
        }
        return (r.double("position") ?? 0, (r.int("completed") ?? 0) != 0)
    }

    // MARK: Scrobble backlog

    public func enqueueScrobble(_ e: ScrobbleEntry) throws {
        try db.execute("INSERT INTO scrobble_queue (entry_json) VALUES (?)", [try encoder.encode(e)])
    }

    public func pendingScrobbles(limit: Int = 50) throws -> [(id: Int, entry: ScrobbleEntry)] {
        try db.query("SELECT * FROM scrobble_queue ORDER BY id LIMIT ?", [limit]).compactMap { r in
            guard let id = r.int("id"), let d = r.data("entry_json"), let e = try? decoder.decode(ScrobbleEntry.self, from: d) else {
                return nil
            }
            return (id, e)
        }
    }

    public func removeScrobbles(ids: [Int]) throws {
        try db.transaction { tx in
            for id in ids { try tx.execute("DELETE FROM scrobble_queue WHERE id = ?", [id]) }
        }
    }
}
