// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// The user's own Last.fm API application. WaveLast ships no key: each user
/// creates one at https://www.last.fm/api/account/create (free, non-commercial).
public struct LastFMCredentials: Codable, Equatable, Sendable {
    public var apiKey: String
    public var sharedSecret: String

    public init(apiKey: String, sharedSecret: String) {
        self.apiKey = LastFMSigner.normalizeKey(apiKey)
        self.sharedSecret = LastFMSigner.normalizeKey(sharedSecret)
    }

    public var isPlausible: Bool { apiKey.count == 32 && sharedSecret.count == 32 }
}

public struct LastFMSession: Codable, Equatable, Sendable {
    public var username: String
    public var key: String

    public init(username: String, key: String) {
        self.username = username
        self.key = key
    }
}

/// Error codes documented at https://www.last.fm/api/errorcodes
public struct LastFMAPIError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    /// Session is no longer valid; the user must reconnect.
    /// 4 authentication failed, 9 invalid session key, 15 token expired.
    public var requiresReauthentication: Bool { [4, 9, 15].contains(code) }
    /// Temporary on Last.fm's side; safe to retry later.
    public var isTemporary: Bool { [11, 16, 29].contains(code) }
    /// Token not yet authorised by the user in the browser (auth flow step 2).
    public var isUnauthorizedToken: Bool { code == 14 }
}

public struct ScrobbleEntry: Codable, Equatable, Sendable {
    public var artist: String
    public var track: String
    public var album: String?
    public var duration: TimeInterval?
    /// Unix time the track started playing.
    public var timestamp: Int

    public init(artist: String, track: String, album: String?, duration: TimeInterval?, timestamp: Int) {
        self.artist = artist
        self.track = track
        self.album = album
        self.duration = duration
        self.timestamp = timestamp
    }
}

public struct LastFMSimilarTrack: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var match: Double
}

/// Official Last.fm API 2.0 client (https://www.last.fm/api).
/// Authentication uses the documented desktop flow: `auth.getToken` → user
/// approves in the browser → `auth.getSession`. WaveLast never sees the
/// user's Last.fm password.
public struct LastFMClient: Sendable {
    public static let apiURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    let http: HTTPClient
    let credentials: LastFMCredentials

    public init(credentials: LastFMCredentials, http: HTTPClient = HTTPClient()) {
        self.credentials = credentials
        self.http = http
    }

    // MARK: Auth

    public func getToken() async throws -> String {
        let json = try await call(method: "auth.getToken", params: [:], signed: true, post: false)
        guard let token = json["token"] as? String else { throw NetworkError.invalidResponse("auth.getToken: no token") }
        return token
    }

    /// URL the user opens to approve WaveLast for their Last.fm account.
    public func authorizationURL(token: String) -> URL {
        var c = URLComponents(string: "https://www.last.fm/api/auth/")!
        c.queryItems = [URLQueryItem(name: "api_key", value: credentials.apiKey), URLQueryItem(name: "token", value: token)]
        return c.url!
    }

    public func getSession(token: String) async throws -> LastFMSession {
        let json = try await call(method: "auth.getSession", params: ["token": token], signed: true, post: false)
        guard let s = json["session"] as? [String: Any], let name = s["name"] as? String, let key = s["key"] as? String else {
            throw NetworkError.invalidResponse("auth.getSession: no session")
        }
        return LastFMSession(username: name, key: key)
    }

    // MARK: Scrobbling

    public func updateNowPlaying(_ e: ScrobbleEntry, session: LastFMSession) async throws {
        var p = ["artist": e.artist, "track": e.track, "sk": session.key]
        if let a = e.album, !a.isEmpty { p["album"] = a }
        if let d = e.duration, d > 0 { p["duration"] = String(Int(d)) }
        _ = try await call(method: "track.updateNowPlaying", params: p, signed: true, post: true)
    }

    /// Submits up to 50 scrobbles (Last.fm's batch limit). Returns how many
    /// Last.fm accepted.
    @discardableResult
    public func scrobble(_ entries: [ScrobbleEntry], session: LastFMSession) async throws -> Int {
        precondition(entries.count <= 50, "Last.fm accepts at most 50 scrobbles per request")
        guard !entries.isEmpty else { return 0 }
        var p = ["sk": session.key]
        for (i, e) in entries.enumerated() {
            p["artist[\(i)]"] = e.artist
            p["track[\(i)]"] = e.track
            p["timestamp[\(i)]"] = String(e.timestamp)
            if let a = e.album, !a.isEmpty { p["album[\(i)]"] = a }
            if let d = e.duration, d > 0 { p["duration[\(i)]"] = String(Int(d)) }
        }
        let json = try await call(method: "track.scrobble", params: p, signed: true, post: true)
        let attr = (json["scrobbles"] as? [String: Any])?["@attr"] as? [String: Any]
        if let accepted = attr?["accepted"] as? Int { return accepted }
        if let s = attr?["accepted"] as? String, let n = Int(s) { return n }
        return entries.count
    }

    // MARK: Recommendations

    public func similarTracks(artist: String, track: String, limit: Int = 30) async throws -> [LastFMSimilarTrack] {
        let json = try await call(
            method: "track.getSimilar",
            params: ["artist": artist, "track": track, "limit": String(limit), "autocorrect": "1"],
            signed: false, post: false)
        let list = ((json["similartracks"] as? [String: Any])?["track"] as? [[String: Any]]) ?? []
        return list.compactMap { t in
            guard let name = t["name"] as? String,
                let artistName = (t["artist"] as? [String: Any])?["name"] as? String
            else { return nil }
            let match = (t["match"] as? Double) ?? Double((t["match"] as? String) ?? "") ?? 0
            return LastFMSimilarTrack(title: name, artist: artistName, match: match)
        }
    }

    public func topArtists(user: String, period: String = "3month", limit: Int = 20) async throws -> [String] {
        let json = try await call(
            method: "user.getTopArtists",
            params: ["user": user, "period": period, "limit": String(limit)],
            signed: false, post: false)
        let list = ((json["topartists"] as? [String: Any])?["artist"] as? [[String: Any]]) ?? []
        return list.compactMap { $0["name"] as? String }
    }

    // MARK: Transport

    /// Builds the request for a method call. Exposed for request-signing tests.
    public func makeRequest(method: String, params: [String: String], signed: Bool, post: Bool) -> URLRequest {
        var all = params
        all["method"] = method
        all["api_key"] = credentials.apiKey
        if signed { all["api_sig"] = LastFMSigner.sign(all, secret: credentials.sharedSecret) }
        all["format"] = "json"
        let items = all.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        if post {
            var req = URLRequest(url: Self.apiURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.formEncode(items).utf8)
            return req
        }
        var c = URLComponents(url: Self.apiURL, resolvingAgainstBaseURL: false)!
        c.queryItems = items
        return URLRequest(url: c.url!)
    }

    static func formEncode(_ items: [URLQueryItem]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.map { item in
            let k = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
            let v = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    func call(method: String, params: [String: String], signed: Bool, post: Bool) async throws -> [String: Any] {
        let req = makeRequest(method: method, params: params, signed: signed, post: post)
        // Last.fm reports API errors as 4xx with a JSON body, so read the body
        // whatever the status is.
        let (data, status) = try await http.response(for: req)
        return try Self.parse(data, status: status)
    }

    static func parse(_ data: Data, status: Int = 200) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let code = json?["error"] as? Int {
            throw LastFMAPIError(code: code, message: json?["message"] as? String ?? "Last.fm error \(code)")
        }
        guard (200..<300).contains(status) else { throw NetworkError.http(status: status) }
        guard let json else { throw NetworkError.invalidResponse("Last.fm: response is not a JSON object") }
        return json
    }
}

/// Last.fm scrobbling rules (https://www.last.fm/api/scrobbling):
/// a track is scrobbled when it is longer than 30 seconds and has been played
/// for at least half its duration or 4 minutes, whichever comes first.
public enum ScrobbleRules {
    public static let minimumTrackLength: TimeInterval = 30
    public static let maximumThreshold: TimeInterval = 240

    /// Listening time required before the track counts, or nil if it can never count.
    public static func threshold(forDuration duration: TimeInterval?) -> TimeInterval? {
        guard let d = duration, d > minimumTrackLength else { return nil }
        return min(d / 2, maximumThreshold)
    }

    public static func shouldScrobble(duration: TimeInterval?, listened: TimeInterval) -> Bool {
        guard let t = threshold(forDuration: duration) else { return false }
        return listened >= t
    }
}
