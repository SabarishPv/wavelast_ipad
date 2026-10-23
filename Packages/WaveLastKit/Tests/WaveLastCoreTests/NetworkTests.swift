// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing

@testable import WaveLastCore

@Suite("HTTP client: timeouts, retries, offline, invalid responses")
struct HTTPClientTests {
    let req = URLRequest(url: URL(string: "https://api.example.com/x")!)

    @Test func retriesServerErrorsWithBackoffThenSucceeds() async throws {
        let t = MockTransport([status(503), status(502), .response(status: 200, body: Data("ok".utf8))])
        let rec = SleepRecorder()
        let data = try await client(t, retries: 3, recorder: rec).data(for: req)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(t.requestCount == 3)
        #expect(rec.delays == [0.5, 1.0])
    }

    @Test func givesUpAfterMaxAttempts() async {
        let t = MockTransport([status(500), status(500), status(500), status(200)])
        await #expect(throws: NetworkError.http(status: 500)) {
            _ = try await client(t, retries: 3).data(for: req)
        }
        #expect(t.requestCount == 3)
    }

    @Test func doesNotRetryClientErrors() async {
        let t = MockTransport([status(404), status(200)])
        await #expect(throws: NetworkError.http(status: 404)) {
            _ = try await client(t).data(for: req)
        }
        #expect(t.requestCount == 1)
    }

    @Test func honoursRetryAfterOn429() async throws {
        let t = MockTransport([.response(status: 429, body: Data(), headers: ["Retry-After": "3"]), status(200)])
        let rec = SleepRecorder()
        _ = try await client(t, recorder: rec).data(for: req)
        #expect(rec.delays == [3])
    }

    @Test func timeoutIsRetriedAndReported() async {
        let t = MockTransport([.error(URLError(.timedOut)), .error(URLError(.timedOut))])
        await #expect(throws: NetworkError.timedOut) {
            _ = try await client(t, retries: 2).data(for: req)
        }
        #expect(t.requestCount == 2)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed])
    func offlineIsNotRetried(code: URLError.Code) async {
        let t = MockTransport([.error(URLError(code)), status(200)])
        await #expect(throws: NetworkError.offline) {
            _ = try await client(t).data(for: req)
        }
        #expect(t.requestCount == 1)
    }

    @Test func setsTimeoutAndUserAgent() async throws {
        let t = MockTransport([status(200)])
        _ = try await client(t).data(for: req)
        #expect(t.requests[0].timeoutInterval == 5)
        #expect(t.requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("WaveLast/") == true)
    }

    @Test func undecodableJSONIsInvalidResponse() async {
        struct Thing: Decodable { let a: Int }
        let t = MockTransport([.response(status: 200, body: Data("<html>".utf8))])
        await #expect {
            _ = try await client(t).decode(Thing.self, from: req)
        } throws: { e in
            if case NetworkError.invalidResponse = e { return true }
            return false
        }
    }

    @Test func cancellationStopsRetrying() async {
        let t = MockTransport([status(503), status(503), status(503)])
        let c = HTTPClient(transport: t, retry: RetryPolicy(maxAttempts: 3), sleep: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            _ = try await c.data(for: req)
        }
        #expect(t.requestCount == 1)
    }

    @Test func backoffIsCapped() {
        let p = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 5)
        #expect(p.delay(forAttempt: 1, retryAfter: nil) == 1)
        #expect(p.delay(forAttempt: 3, retryAfter: nil) == 4)
        #expect(p.delay(forAttempt: 8, retryAfter: nil) == 5)
        #expect(p.delay(forAttempt: 1, retryAfter: 60) == 5)
    }
}

@Suite("LRCLIB client (fixtures)")
struct LRCLIBTests {
    @Test func exactMatchReturnsSyncedLyricsAndSendsExpectedQuery() async throws {
        let t = MockTransport([ok("lrclib_get.json")])
        let lyrics = try await LRCLIBClient(http: client(t)).lyrics(
            title: "I Want to Live", artist: "Borislav Slavov", album: "Baldur's Gate 3", duration: 233.4)
        guard case .synced(let lines)? = lyrics else { Issue.record("expected synced lyrics"); return }
        #expect(lines.count == 3)
        #expect(lines[0].text == "I feel your breath upon my neck")
        #expect(abs(lines[1].time - 21.79) < 0.001)
        let q = queryItems(t.requests[0])
        #expect(t.requests[0].url?.path == "/api/get")
        #expect(q["track_name"] == "I Want to Live")
        #expect(q["artist_name"] == "Borislav Slavov")
        #expect(q["duration"] == "233")
    }

    @Test func notFoundFallsBackToSearchAndPicksBestMatch() async throws {
        let t = MockTransport([status(404, #"{"code":404,"name":"TrackNotFound"}"#), ok("lrclib_search.json")])
        let lyrics = try await LRCLIBClient(http: client(t)).lyrics(title: "Song Title", artist: "The Band", album: nil, duration: 200)
        guard case .synced(let lines)? = lyrics else { Issue.record("expected synced"); return }
        #expect(lines.first?.text == "studio words", "the live version must lose to the studio match")
        #expect(t.requests[1].url?.path == "/api/search")
    }

    @Test func nothingFoundIsNil() async throws {
        let t = MockTransport([status(404), .response(status: 200, body: Data("[]".utf8))])
        let lyrics = try await LRCLIBClient(http: client(t)).lyrics(title: "a", artist: "b", album: nil, duration: nil)
        #expect(lyrics == nil)
    }

    @Test func instrumentalAndPlainVariants() {
        let inst = LRCLIBClient.Record(
            id: 1, trackName: nil, artistName: nil, albumName: nil, duration: nil,
            instrumental: true, plainLyrics: nil, syncedLyrics: nil)
        #expect(LRCLIBClient.lyrics(from: inst) == .instrumental)
        let plain = LRCLIBClient.Record(
            id: 1, trackName: nil, artistName: nil, albumName: nil, duration: nil,
            instrumental: false, plainLyrics: " words \n", syncedLyrics: "")
        #expect(LRCLIBClient.lyrics(from: plain) == .plain("words"))
    }

    @Test func offlineSurfacesAsNetworkError() async {
        let t = MockTransport([.error(URLError(.notConnectedToInternet))])
        await #expect(throws: NetworkError.offline) {
            _ = try await LRCLIBClient(http: client(t)).lyrics(title: "a", artist: "b", album: nil, duration: nil)
        }
    }
}

@Suite("Podcast RSS parsing")
struct PodcastTests {
    let feedURL = URL(string: "https://example.com/feed.xml")!

    @Test func parsesChannelAndAudioEpisodes() throws {
        let feed = try PodcastFeedParser.parse(Fixture.data("podcast_feed.xml"), feedURL: feedURL)
        #expect(feed.title == "The Test Show")
        #expect(feed.author == "Test Author")
        #expect(feed.summary == "A show about <b>testing</b>.")
        #expect(feed.artworkURL?.absoluteString == "https://example.com/show.jpg")
        #expect(
            feed.episodes.map(\.title) == ["Episode 3: Hours", "Episode 2: Minutes", "Episode 1: Seconds"],
            "video and enclosure-less items are skipped")

        let e3 = feed.episodes[0]
        #expect(e3.guid == "ep-3")
        #expect(e3.duration == 3723)
        #expect(e3.byteLength == 12_345_678)
        #expect(e3.artworkURL?.absoluteString == "https://example.com/ep3.jpg")
        #expect(e3.publishedAt == Date(timeIntervalSince1970: 1_761_035_400))
        #expect(e3.summary == "Third <i>episode</i>")

        let e2 = feed.episodes[1]
        #expect(e2.guid == "https://cdn.example.com/ep2.m4a", "missing guid falls back to enclosure URL")
        #expect(e2.duration == 2710)
        #expect(e2.publishedAt == Date(timeIntervalSince1970: 1_759_739_400))
        #expect(feed.episodes[2].duration == 930)
    }

    @Test func episodeBecomesPodcastTrack() throws {
        let feed = try PodcastFeedParser.parse(Fixture.data("podcast_feed.xml"), feedURL: feedURL)
        let t = feed.episodes[0].track(in: feed)
        #expect(t.source == .podcast)
        #expect(t.artist == "Test Author")
        #expect(t.album == "The Test Show")
        #expect(
            t.location
                == .podcastEpisode(feedURL: feedURL, episodeGUID: "ep-3", enclosureURL: URL(string: "https://cdn.example.com/ep3.mp3")!))
    }

    @Test func rejectsNonRSSAndMalformedXML() {
        #expect(throws: PodcastParseError.notRSS) {
            _ = try PodcastFeedParser.parse(Data("<html><body>hi</body></html>".utf8), feedURL: feedURL)
        }
        #expect {
            _ = try PodcastFeedParser.parse(Data("<rss><channel><title>x</channel>".utf8), feedURL: feedURL)
        } throws: { e in
            if case PodcastParseError.malformed = e { return true }
            return false
        }
    }

    @Test(arguments: [("90", 90.0), ("1:30", 90.0), ("01:00:01", 3601.0), ("12.5", 12.5)])
    func durations(_ s: String, _ v: TimeInterval) {
        #expect(PodcastFeedParser.parseDuration(s) == v)
    }

    @Test(arguments: ["", "abc", "1:2:3:4", "-5"])
    func badDurations(_ s: String) {
        #expect(PodcastFeedParser.parseDuration(s) == nil)
    }

    @Test func loaderMapsHTTPAndParseFailures() async throws {
        let good = MockTransport([ok("podcast_feed.xml")])
        let feed = try await PodcastFeedLoader(http: client(good)).load(feedURL)
        #expect(feed.episodes.count == 3)

        let bad = MockTransport([.response(status: 200, body: Data("not xml".utf8))])
        await #expect {
            _ = try await PodcastFeedLoader(http: client(bad)).load(feedURL)
        } throws: { e in
            if case NetworkError.invalidResponse = e { return true }
            return false
        }
        let missing = MockTransport([status(404)])
        await #expect(throws: NetworkError.http(status: 404)) {
            _ = try await PodcastFeedLoader(http: client(missing)).load(feedURL)
        }
    }
}
