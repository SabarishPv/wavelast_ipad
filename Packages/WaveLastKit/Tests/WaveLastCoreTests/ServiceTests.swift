// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing

@testable import WaveLastCore

let testCredentials = LastFMCredentials(apiKey: "0123456789abcdef0123456789abcdef", sharedSecret: "fedcba9876543210fedcba9876543210")
let testSession = LastFMSession(username: "testuser", key: "SESSIONKEY")

@Suite("Last.fm signing, requests and errors")
struct LastFMTests {
    @Test func signatureMatchesIndependentReference() {
        // Expected value computed independently with Python hashlib, following
        // https://www.last.fm/api/authspec (sorted key+value pairs + secret, MD5).
        let params = [
            "method": "track.scrobble", "api_key": testCredentials.apiKey, "sk": "SESSIONKEY",
            "artist[0]": "Björk", "track[0]": "Jóga", "timestamp[0]": "1700000000", "format": "json",
        ]
        #expect(LastFMSigner.sign(params, secret: testCredentials.sharedSecret) == "ce618c83868c7271eb9710ac515c6b19")
    }

    @Test func signatureIgnoresFormatCallbackAndExistingSig() {
        let base = ["method": "auth.getSession", "api_key": "k", "token": "t"]
        var noisy = base
        noisy["format"] = "json"
        noisy["callback"] = "cb"
        noisy["api_sig"] = "old"
        #expect(LastFMSigner.sign(base, secret: "s") == LastFMSigner.sign(noisy, secret: "s"))
    }

    @Test func normalisesPastedKeys() {
        #expect(LastFMSigner.normalizeKey(" 0123456789ABCDEF0123456789abcdef\u{200B}\n") == "0123456789abcdef0123456789abcdef")
        #expect(LastFMCredentials(apiKey: "short", sharedSecret: "x").isPlausible == false)
        #expect(testCredentials.isPlausible)
    }

    @Test func scrobbleRequestIsSignedFormPOST() throws {
        let c = LastFMClient(credentials: testCredentials)
        let req = c.makeRequest(
            method: "track.scrobble",
            params: ["sk": "SESSIONKEY", "artist[0]": "Björk", "track[0]": "Jóga", "timestamp[0]": "1700000000"],
            signed: true, post: true)
        #expect(req.httpMethod == "POST")
        #expect(req.url == LastFMClient.apiURL)
        let form = formItems(req)
        #expect(form["api_sig"] == "ce618c83868c7271eb9710ac515c6b19")
        #expect(form["format"] == "json")
        #expect(form["artist[0]"] == "Björk", "UTF-8 survives form encoding")
        #expect(form["method"] == "track.scrobble")
    }

    @Test func unsignedGETHasNoSignature() {
        let req = LastFMClient(credentials: testCredentials).makeRequest(
            method: "track.getSimilar", params: ["artist": "a", "track": "b"], signed: false, post: false)
        let q = queryItems(req)
        #expect(req.httpMethod == "GET")
        #expect(q["api_sig"] == nil)
        #expect(q["api_key"] == testCredentials.apiKey)
    }

    @Test func authFlowParsesSession() async throws {
        let t = MockTransport([.response(status: 200, body: Data(#"{"token":"tok123"}"#.utf8)), ok("lastfm_session.json")])
        let c = LastFMClient(credentials: testCredentials, http: client(t))
        let token = try await c.getToken()
        #expect(token == "tok123")
        let url = c.authorizationURL(token: token)
        #expect(url.absoluteString.hasPrefix("https://www.last.fm/api/auth/"))
        #expect(queryItems(URLRequest(url: url))["token"] == "tok123")
        let s = try await c.getSession(token: token)
        #expect(s == LastFMSession(username: "testuser", key: "d580d57f32848f5dcf574d1ce18d78b2"))
        #expect(queryItems(t.requests[1])["api_sig"] != nil, "auth.getSession must be signed")
    }

    @Test func apiErrorInFourHundredBodyIsDecoded() async {
        let t = MockTransport([.response(status: 403, body: Fixture.data("lastfm_error_session.json"))])
        let c = LastFMClient(credentials: testCredentials, http: client(t))
        await #expect {
            try await c.updateNowPlaying(
                ScrobbleEntry(artist: "a", track: "b", album: nil, duration: nil, timestamp: 0), session: testSession)
        } throws: { e in
            guard let e = e as? LastFMAPIError else { return false }
            return e.code == 9 && e.requiresReauthentication && !e.isTemporary
        }
    }

    @Test func temporaryErrorsAreFlagged() {
        #expect(LastFMAPIError(code: 11, message: "").isTemporary)
        #expect(LastFMAPIError(code: 29, message: "").isTemporary)
        #expect(LastFMAPIError(code: 14, message: "").isUnauthorizedToken)
        #expect(!LastFMAPIError(code: 14, message: "").requiresReauthentication)
    }

    @Test func scrobbleBatchEncodesIndexedParams() async throws {
        let t = MockTransport([ok("lastfm_scrobble_ok.json")])
        let c = LastFMClient(credentials: testCredentials, http: client(t))
        let accepted = try await c.scrobble(
            [
                ScrobbleEntry(artist: "A", track: "One", album: "LP", duration: 200, timestamp: 100),
                ScrobbleEntry(artist: "B", track: "Two", album: nil, duration: nil, timestamp: 200),
            ], session: testSession)
        #expect(accepted == 2)
        let f = formItems(t.requests[0])
        #expect(f["artist[1]"] == "B")
        #expect(f["album[0]"] == "LP")
        #expect(f["album[1]"] == nil)
        #expect(f["duration[0]"] == "200")
        #expect(f["sk"] == "SESSIONKEY")
    }

    @Test func similarTracksParsingToleratesStringScoresAndBadEntries() async throws {
        let t = MockTransport([ok("lastfm_similar.json")])
        let r = try await LastFMClient(credentials: testCredentials, http: client(t)).similarTracks(artist: "Björk", track: "Jóga")
        #expect(
            r == [
                LastFMSimilarTrack(title: "Hyperballad", artist: "Björk", match: 1.0),
                LastFMSimilarTrack(title: "Teardrop", artist: "Massive Attack", match: 0.83),
            ])
    }

    @Test func serverErrorWithoutJSONIsHTTPError() async {
        let t = MockTransport([status(400, "<html>bad</html>")])
        await #expect(throws: NetworkError.http(status: 400)) {
            _ = try await LastFMClient(credentials: testCredentials, http: client(t)).getToken()
        }
    }

    @Test(arguments: [
        (nil as TimeInterval?, 1000.0, false),
        (30.0, 30.0, false),
        (31.0, 15.4, false),
        (31.0, 15.5, true),
        (200.0, 100.0, true),
        (1200.0, 239.0, false),
        (1200.0, 240.0, true),
    ])
    func scrobbleRules(duration: TimeInterval?, listened: TimeInterval, expected: Bool) {
        #expect(ScrobbleRules.shouldScrobble(duration: duration, listened: listened) == expected)
    }
}

@Suite("Subsonic client (fixtures)")
struct SubsonicTests {
    let config = SubsonicConfiguration(serverURL: URL(string: "https://music.example.com/navidrome")!, username: "joe", password: "sesame")

    @Test func tokenAuthMatchesProtocolDocumentation() {
        // Worked example from http://www.subsonic.org/pages/api.jsp:
        // password "sesame", salt "c19b2d" → t = 26719a1196d2a940705a59634eb18eab
        let c = SubsonicClient(config: config, makeSalt: { "c19b2d" })
        let url = c.url("ping")
        let q = queryItems(URLRequest(url: url))
        #expect(url.path == "/navidrome/rest/ping")
        #expect(q["t"] == "26719a1196d2a940705a59634eb18eab")
        #expect(q["s"] == "c19b2d")
        #expect(q["u"] == "joe")
        #expect(q["c"] == "WaveLast")
        #expect(q["p"] == nil, "plain password must never be sent")
        #expect(!url.absoluteString.contains("sesame"))
    }

    @Test func saltIsRandomPerRequest() {
        let c = SubsonicClient(config: config)
        #expect(queryItems(URLRequest(url: c.url("ping")))["s"] != queryItems(URLRequest(url: c.url("ping")))["s"])
    }

    @Test func searchParsesSongs() async throws {
        let t = MockTransport([ok("subsonic_search.json")])
        let tracks = try await SubsonicClient(config: config, http: client(t)).search("track")
        #expect(tracks.map(\.title) == ["Track One", "Track Two"])
        #expect(tracks[0].location == .subsonic(songID: "s1"))
        #expect(tracks[0].duration == 215)
        #expect(tracks[0].source == .subsonic)
        #expect(queryItems(t.requests[0])["query"] == "track")
    }

    @Test func failedStatusBecomesAuthError() async {
        let t = MockTransport([ok("subsonic_error.json")])
        await #expect {
            try await SubsonicClient(config: config, http: client(t)).ping()
        } throws: { e in
            (e as? SubsonicAPIError)?.isAuthenticationError == true
        }
    }

    @Test func sourceResolvesStreamURL() async throws {
        let src = SubsonicSource(client: SubsonicClient(config: config, makeSalt: { "abc" }))
        let item = try await src.resolve(
            Track(id: "subsonic:s1", title: "t", artist: "a", source: .subsonic, location: .subsonic(songID: "s1")))
        #expect(item.url.path.hasSuffix("/rest/stream"))
        #expect(queryItems(URLRequest(url: item.url))["id"] == "s1")
        await #expect(throws: SourceError.wrongSource) {
            _ = try await src.resolve(makeTrack(1))
        }
    }

    @Test func notASubsonicServer() {
        #expect(throws: NetworkError.self) { _ = try SubsonicClient.parse(Data("{}".utf8)) }
    }
}

@Suite("Source registry")
struct SourceRegistryTests {
    @Test func resolvesLocalFilesAndReportsMissingOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wl-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("Music/t1.m4a"))

        let registry = SourceRegistry([LocalFileSource(libraryRoot: root), PodcastSource()])
        let item = try await registry.resolve(makeTrack(1))
        #expect(item.url.lastPathComponent == "t1.m4a")
        await #expect(throws: SourceError.trackNotFound) { _ = try await registry.resolve(makeTrack(2)) }
    }

    @Test func unknownSourceIsNotConfigured() async {
        let registry = SourceRegistry()
        await #expect(throws: SourceError.notConfigured("Subsonic")) {
            _ = try await registry.resolve(Track(id: "x", title: "x", artist: "", source: .subsonic, location: .subsonic(songID: "1")))
        }
    }

    @Test func podcastSourceUsesEnclosure() async throws {
        let enc = URL(string: "https://cdn.example.com/a.mp3")!
        let t = Track(
            id: "p", title: "p", artist: "", source: .podcast,
            location: .podcastEpisode(feedURL: URL(string: "https://e.com/f")!, episodeGUID: "g", enclosureURL: enc))
        #expect(try await PodcastSource().resolve(t).url == enc)
    }
}
