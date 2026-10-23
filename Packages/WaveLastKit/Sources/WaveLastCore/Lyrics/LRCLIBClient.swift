// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// Client for the open LRCLIB API (https://lrclib.net/docs). No key needed.
public struct LRCLIBClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://lrclib.net")!

    let http: HTTPClient
    let baseURL: URL

    public init(http: HTTPClient = HTTPClient(), baseURL: URL = LRCLIBClient.defaultBaseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    struct Record: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Looks up lyrics for one track. Returns nil when LRCLIB has none.
    /// Tries the exact `/api/get` lookup first, then falls back to `/api/search`
    /// and picks the best match by title/artist/duration.
    public func lyrics(title: String, artist: String, album: String?, duration: TimeInterval?) async throws -> Lyrics? {
        if let exact = try await get(title: title, artist: artist, album: album, duration: duration) {
            return Self.lyrics(from: exact)
        }
        let candidates = try await search(title: title, artist: artist)
        let best =
            candidates
            .map { rec in
                (
                    rec,
                    TextMatch.matchScore(
                        wantedTitle: title, wantedArtist: artist, wantedDuration: duration,
                        candidateTitle: rec.trackName ?? "", candidateArtist: rec.artistName ?? "",
                        candidateDuration: rec.duration)
                )
            }
            .filter { $0.1 >= 0.55 }
            .max { $0.1 < $1.1 }
        return best.flatMap { Self.lyrics(from: $0.0) }
    }

    func get(title: String, artist: String, album: String?, duration: TimeInterval?) async throws -> Record? {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration, duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        c.queryItems = items
        do {
            return try await http.decode(Record.self, from: URLRequest(url: c.url!))
        } catch NetworkError.http(status: 404) {
            return nil
        }
    }

    func search(title: String, artist: String) async throws -> [Record] {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        do {
            return try await http.decode([Record].self, from: URLRequest(url: c.url!))
        } catch NetworkError.http(status: 404) {
            return []
        }
    }

    static func lyrics(from r: Record) -> Lyrics? {
        if r.instrumental == true { return .instrumental }
        if let synced = r.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = r.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .plain(plain)
        }
        return nil
    }
}
