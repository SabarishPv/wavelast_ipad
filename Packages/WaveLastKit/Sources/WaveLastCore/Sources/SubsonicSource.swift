// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// Connection details for a server the user runs or has an account on
/// (Navidrome, Airsonic, Gonic, Subsonic…). Protocol docs:
/// http://www.subsonic.org/pages/api.jsp and https://opensubsonic.netlify.app
public struct SubsonicConfiguration: Codable, Equatable, Sendable {
    public var serverURL: URL
    public var username: String
    /// Stored in the Keychain by the app; never written to the database.
    public var password: String

    public init(serverURL: URL, username: String, password: String) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
    }
}

public struct SubsonicAPIError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    /// 40 wrong credentials, 41 token auth unsupported (LDAP), 44 invalid API key.
    public var isAuthenticationError: Bool { [40, 41, 44].contains(code) }
}

/// Subsonic REST client using token authentication (t = md5(password + salt)),
/// so the plain password is never sent over the network.
public struct SubsonicClient: Sendable {
    public static let apiVersion = "1.16.1"
    public static let clientName = "WaveLast"

    let config: SubsonicConfiguration
    let http: HTTPClient
    let makeSalt: @Sendable () -> String

    public init(
        config: SubsonicConfiguration, http: HTTPClient = HTTPClient(),
        makeSalt: @escaping @Sendable () -> String = { SubsonicClient.randomSalt() }
    ) {
        self.config = config
        self.http = http
        self.makeSalt = makeSalt
    }

    public static func randomSalt() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<12).map { _ in String(format: "%x", Int.random(in: 0..<16, using: &g)) }.joined()
    }

    /// Builds an authenticated endpoint URL. Public for tests and for stream URLs.
    public func url(_ endpoint: String, _ params: [String: String] = [:]) -> URL {
        let salt = makeSalt()
        let base = config.serverURL.appendingPathComponent("rest").appendingPathComponent(endpoint)
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: LastFMSigner.md5Hex(config.password + salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items += params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = (c.queryItems ?? []) + items
        return c.url!
    }

    public func ping() async throws {
        _ = try await call("ping")
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [Track] {
        let body = try await call("search3", ["query": query, "songCount": String(limit), "albumCount": "0", "artistCount": "0"])
        let songs = ((body["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]]) ?? []
        return songs.compactMap(Self.track(from:))
    }

    public func streamURL(songID: String) -> URL { url("stream", ["id": songID]) }

    public func coverArtURL(id: String, size: Int = 600) -> URL { url("getCoverArt", ["id": id, "size": String(size)]) }

    static func track(from s: [String: Any]) -> Track? {
        guard let id = s["id"] as? String ?? (s["id"] as? Int).map(String.init),
            let title = s["title"] as? String
        else { return nil }
        return Track(
            id: "subsonic:\(id)",
            title: title,
            artist: s["artist"] as? String ?? "",
            album: s["album"] as? String ?? "",
            duration: (s["duration"] as? Int).map(TimeInterval.init) ?? (s["duration"] as? Double),
            trackNumber: s["track"] as? Int,
            source: .subsonic,
            location: .subsonic(songID: id),
            artworkRef: (s["coverArt"] as? String).map { "subsonic-cover:\($0)" })
    }

    func call(_ endpoint: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await http.data(for: URLRequest(url: url(endpoint, params)))
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let body = root["subsonic-response"] as? [String: Any]
        else {
            throw NetworkError.invalidResponse("Not a Subsonic response")
        }
        if (body["status"] as? String) != "ok" {
            let err = body["error"] as? [String: Any]
            throw SubsonicAPIError(code: err?["code"] as? Int ?? 0, message: err?["message"] as? String ?? "Subsonic error")
        }
        return body
    }
}

public struct SubsonicSource: SourceProvider {
    public let id: SourceID = .subsonic
    public let displayName = "Music Server"
    public let capabilities: SourceCapabilities = [.search, .streaming]
    let client: SubsonicClient

    public init(client: SubsonicClient) { self.client = client }

    public func search(_ query: String) async throws -> [Track] {
        do { return try await client.search(query) } catch let e as NetworkError { throw SourceError.network(e) }
    }

    public func resolve(_ track: Track) async throws -> PlayableItem {
        guard case .subsonic(let songID) = track.location else { throw SourceError.wrongSource }
        return PlayableItem(url: client.streamURL(songID: songID))
    }
}
