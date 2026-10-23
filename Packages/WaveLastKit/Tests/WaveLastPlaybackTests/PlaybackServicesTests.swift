// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import MediaPlayer
import Testing

@testable import WaveLastCore
@testable import WaveLastPlayback

@Suite("Audio session policy")
struct AudioSessionPolicyTests {
    @Test func interruptionWhilePlayingPausesThenResumes() {
        var p = AudioSessionPolicy()
        #expect(p.handle(.interruptionBegan, isPlaying: true) == .pause)
        #expect(p.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .resume)
    }

    @Test func noResumeWhenSystemSaysNo() {
        var p = AudioSessionPolicy()
        _ = p.handle(.interruptionBegan, isPlaying: true)
        #expect(p.handle(.interruptionEnded(shouldResume: false), isPlaying: false) == .none)
    }

    @Test func noResumeIfUserWasPaused() {
        var p = AudioSessionPolicy()
        #expect(p.handle(.interruptionBegan, isPlaying: false) == .none)
        #expect(p.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
    }

    @Test func stateResetsAfterEachInterruption() {
        var p = AudioSessionPolicy()
        _ = p.handle(.interruptionBegan, isPlaying: true)
        _ = p.handle(.interruptionEnded(shouldResume: true), isPlaying: false)
        _ = p.handle(.interruptionBegan, isPlaying: false)
        #expect(p.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
    }

    @Test func nestedInterruptionsRememberOriginalState() {
        var p = AudioSessionPolicy()
        _ = p.handle(.interruptionBegan, isPlaying: true)
        // A second "began" arrives while already paused by the first.
        _ = p.handle(.interruptionBegan, isPlaying: false)
        #expect(p.handle(.interruptionEnded(shouldResume: true), isPlaying: false) == .resume)
    }

    @Test func routeChanges() {
        var p = AudioSessionPolicy()
        #expect(p.handle(.routeChanged(.oldDeviceUnavailable), isPlaying: true) == .pause)
        #expect(p.handle(.routeChanged(.oldDeviceUnavailable), isPlaying: false) == .none)
        #expect(p.handle(.routeChanged(.newDeviceAvailable), isPlaying: false) == .none, "never auto-play on connect")
        #expect(p.handle(.routeChanged(.other), isPlaying: true) == .none)
        #expect(p.handle(.mediaServicesReset, isPlaying: true) == .rebuildPlayer)
    }

    @Test func backgroundAudioConfigurationCheck() {
        #expect(BackgroundAudioConfiguration.validate(infoDictionary: ["UIBackgroundModes": ["audio"]]))
        #expect(!BackgroundAudioConfiguration.validate(infoDictionary: ["UIBackgroundModes": ["fetch"]]))
        #expect(!BackgroundAudioConfiguration.validate(infoDictionary: [:]))
        #expect(!BackgroundAudioConfiguration.validate(infoDictionary: nil))
    }
}

@Suite("Now Playing metadata")
struct NowPlayingTests {
    @Test func buildsLockScreenInfo() {
        let t = Track(
            id: "1", title: "Song", artist: "Singer", album: "Record", duration: 210, source: .local,
            location: .localFile(relativePath: "a"))
        let info = NowPlayingInfoBuilder.info(track: t, elapsed: 12.5, duration: 211, isPlaying: true, queueIndex: 2, queueCount: 9)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Song")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Singer")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Record")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 211, "measured duration wins over metadata")
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 2)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 9)
    }

    @Test func pausedUnknownAndEmptyFields() {
        let t = Track(id: "1", title: "", artist: "", source: .local, location: .localFile(relativePath: "a"))
        let info = NowPlayingInfoBuilder.info(track: t, elapsed: -1, duration: nil, isPlaying: false, queueIndex: nil, queueCount: 0)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Unknown Title")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Unknown Artist")
        #expect(info[MPMediaItemPropertyAlbumTitle] == nil)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
    }
}

@Suite("Local file import")
struct LocalImportTests {
    @Test func importsWAVCopiesFileAndReadsMetadataFromName() async throws {
        let src = try tempDir(), lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: lib) }
        let wav = src.appendingPathComponent("03 - The Artist - Song Name.wav")
        try writeWAV(to: wav, seconds: 1.5)

        let importer = LocalImporter(libraryRoot: lib)
        let result = await importer.importFiles([wav], existingIDs: [])
        #expect(result.failed.isEmpty, "\(result.failed)")
        let t = try #require(result.imported.first)
        #expect(t.title == "Song Name")
        #expect(t.artist == "The Artist")
        #expect(abs((t.duration ?? 0) - 1.5) < 0.05)
        #expect(t.source == .local)
        guard case .localFile(let rel) = t.location else { Issue.record("wrong location"); return }
        #expect(FileManager.default.fileExists(atPath: lib.appendingPathComponent(rel).path))

        // Importing the same bytes again (even renamed) is a duplicate.
        let copy = src.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(at: wav, to: copy)
        let again = await importer.importFiles([copy], existingIDs: [t.id])
        #expect(again.imported.isEmpty)
        #expect(again.duplicates == ["renamed.wav"])

        // And the copied file resolves for playback.
        let item = try await LocalFileSource(libraryRoot: lib).resolve(t)
        #expect(FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test func rejectsUnsupportedAndCorruptFiles() async throws {
        let src = try tempDir(), lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: lib) }
        let ogg = src.appendingPathComponent("song.ogg")
        let txt = src.appendingPathComponent("notes.txt")
        let fake = src.appendingPathComponent("broken.mp3")
        try Data("OggS....".utf8).write(to: ogg)
        try Data("hello".utf8).write(to: txt)
        try Data(repeating: 0x42, count: 2048).write(to: fake)
        let r = await LocalImporter(libraryRoot: lib).importFiles([ogg, txt, fake], existingIDs: [])
        #expect(r.unsupported.sorted() == ["notes.txt", "song.ogg"])
        #expect(r.imported.isEmpty)
        #expect(r.failed["broken.mp3"] != nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: lib.appendingPathComponent("Music").path)) ?? []
        #expect(leftovers.isEmpty, "a file that can't be played is not kept")
    }

    @Test func missingSourceFileIsReported() async throws {
        let lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let r = await LocalImporter(libraryRoot: lib).importFiles([URL(fileURLWithPath: "/nonexistent/x.mp3")], existingIDs: [])
        #expect(r.failed["x.mp3"] != nil)
    }

    @Test(
        arguments: [
            ("Artist - Title", "Artist", "Title"),
            ("01 Title Only", nil, "Title Only"),
            ("07. Band - Song - Remix", "Band", "Song - Remix"),
            ("under_score_name", nil, "under score name"),
        ] as [(String, String?, String)])
    func fileNameParsing(name: String, artist: String?, title: String) {
        let p = LocalImporter.parseFileName(name)
        #expect(p.artist == artist)
        #expect(p.title == title)
    }

    @Test func supportedFormatList() {
        #expect(SupportedAudioFormats.isSupported(URL(fileURLWithPath: "/a/b.FLAC")))
        #expect(SupportedAudioFormats.isSupported(URL(fileURLWithPath: "/a/b.m4a")))
        #expect(!SupportedAudioFormats.isSupported(URL(fileURLWithPath: "/a/b.opus")))
        #expect(SupportedAudioFormats.extensions.isDisjoint(with: SupportedAudioFormats.knownUnsupported))
    }
}

@Suite("Lyrics service")
struct LyricsServiceTests {
    @Test func importedLRCWinsOverNetwork() async throws {
        let src = try tempDir(), lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: lib) }
        let lrc = src.appendingPathComponent("Artist 1 - Track 1.lrc")
        try "[00:01.00]hello\n[00:02.00]world".write(to: lrc, atomically: true, encoding: .utf8)
        let importer = LocalImporter(libraryRoot: lib)
        let r = await importer.importFiles([lrc], existingIDs: [])
        #expect(r.lyricsFiles == ["Artist 1 - Track 1.lrc"])

        // No LRCLIB client: if the local file weren't found this would be notFound.
        let service = LyricsService(lyricsFolder: importer.lyricsFolder, lrclib: nil)
        let result = await service.lyrics(for: makeTrack(1))
        guard case .found(.synced(let lines), .localFile) = result else { Issue.record("got \(result)"); return }
        #expect(lines.map(\.text) == ["hello", "world"])
    }

    @Test func fallsBackToLRCLIBAndCachesResult() async throws {
        let lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let body = #"{"instrumental":false,"plainLyrics":"la la","syncedLyrics":"[00:03.00]la la"}"#
        let t = PBMockTransport([(200, body)])
        let http = HTTPClient(transport: t, retry: .none)
        let service = LyricsService(lyricsFolder: lib, lrclib: LRCLIBClient(http: http))
        let first = await service.lyrics(for: makeTrack(2))
        let second = await service.lyrics(for: makeTrack(2))
        guard case .found(.synced(let lines), .lrclib) = first else { Issue.record("got \(first)"); return }
        #expect(lines.first?.time == 3)
        #expect(first == second)
        #expect(t.count == 1, "second lookup served from cache")
    }

    @Test func networkFailureIsNotCached() async throws {
        let lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let t = PBMockTransport([(-1, ""), (200, #"{"plainLyrics":"ok"}"#)])
        let service = LyricsService(lyricsFolder: lib, lrclib: LRCLIBClient(http: HTTPClient(transport: t, retry: .none)))
        let first = await service.lyrics(for: makeTrack(3))
        #expect(first == .failed(NetworkError.offline.userMessage))
        let second = await service.lyrics(for: makeTrack(3))
        #expect(second == .found(.plain("ok"), .lrclib))
    }

    @Test func podcastsDoNotQueryLRCLIB() async throws {
        let lib = try tempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let t = PBMockTransport([])
        let service = LyricsService(lyricsFolder: lib, lrclib: LRCLIBClient(http: HTTPClient(transport: t, retry: .none)))
        #expect(await service.lyrics(for: podcastTrack()) == .notFound)
        #expect(t.count == 0)
    }
}

@MainActor
@Suite("Last.fm scrobbler backlog")
struct ScrobblerTests {
    let creds = LastFMCredentials(apiKey: "0123456789abcdef0123456789abcdef", sharedSecret: "fedcba9876543210fedcba9876543210")

    func scrobbler(_ t: PBMockTransport, store: LibraryStore) -> LastFMScrobbler {
        let client = LastFMClient(credentials: creds, http: HTTPClient(transport: t, retry: .none))
        return LastFMScrobbler(store: store, makeClient: { (client, LastFMSession(username: "u", key: "k")) })
    }

    @Test func offlineKeepsBacklogAndLaterFlushes() async throws {
        let store = try LibraryStore.inMemory()
        let t = PBMockTransport([(-1, ""), (200, #"{"scrobbles":{"@attr":{"accepted":2}}}"#)])
        let s = scrobbler(t, store: store)
        try store.enqueueScrobble(ScrobbleEntry(artist: "a", track: "1", album: nil, duration: 100, timestamp: 1))
        try store.enqueueScrobble(ScrobbleEntry(artist: "a", track: "2", album: nil, duration: 100, timestamp: 2))
        await s.submitPending()
        #expect(try store.pendingScrobbles().count == 2)
        #expect(s.lastError == NetworkError.offline.userMessage)
        await s.submitPending()
        #expect(try store.pendingScrobbles().isEmpty)
        #expect(s.lastError == nil)
    }

    @Test func invalidSessionKeepsBacklogAndNotifies() async throws {
        let store = try LibraryStore.inMemory()
        let t = PBMockTransport([(403, #"{"error":9,"message":"Invalid session key"}"#)])
        let s = scrobbler(t, store: store)
        var notified = false
        s.onSessionInvalid = { notified = true }
        try store.enqueueScrobble(ScrobbleEntry(artist: "a", track: "1", album: nil, duration: 100, timestamp: 1))
        await s.submitPending()
        #expect(notified)
        #expect(try store.pendingScrobbles().count == 1)
    }

    @Test func permanentlyRejectedBatchIsDropped() async throws {
        let store = try LibraryStore.inMemory()
        let t = PBMockTransport([(400, #"{"error":6,"message":"Invalid parameters"}"#)])
        let s = scrobbler(t, store: store)
        try store.enqueueScrobble(ScrobbleEntry(artist: "", track: "", album: nil, duration: nil, timestamp: 1))
        await s.submitPending()
        #expect(try store.pendingScrobbles().isEmpty)
    }

    @Test func podcastsAreNeverScrobbled() throws {
        let store = try LibraryStore.inMemory()
        let s = scrobbler(PBMockTransport([]), store: store)
        s.scrobble(podcastTrack(), startedAt: Date())
        #expect(try store.pendingScrobbles().isEmpty)
    }
}

@MainActor
@Suite("AVPlayer engine (real AVFoundation, local file)")
struct AVPlayerEngineTests {
    @Test(.timeLimit(.minutes(1)))
    func loadsLocalWAVAndReportsDuration() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try writeWAV(to: wav, seconds: 2)
        let engine = AVPlayerEngine()
        var events: [EngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(PlayableItem(url: wav), autoplay: false)
        for _ in 0..<100
        where !events.contains(where: {
            if case .ready = $0 { return true }; return false
        }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let ready = events.compactMap { e -> TimeInterval?? in
            if case .ready(let d) = e { return d }; return nil
        }.first
        let duration = try #require(ready ?? nil)
        #expect(abs(duration - 2) < 0.05)
        engine.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsFailureForUndecodableFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.m4a")
        try Data(repeating: 0x00, count: 4096).write(to: bad)
        let engine = AVPlayerEngine()
        var failure: PlaybackFailure?
        engine.onEvent = { if case .failed(let f) = $0 { failure = f } }
        engine.load(PlayableItem(url: bad), autoplay: true)
        for _ in 0..<100 where failure == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(failure != nil)
    }
}

/// Minimal transport for this test target: (status, body); status -1 = offline.
final class PBMockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private var _count = 0
    init(_ replies: [(Int, String)]) { self.replies = replies }
    var count: Int { lock.withLock { _count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: (Int, String)? = lock.withLock {
            _count += 1
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let (status, body) = reply else { throw URLError(.unknown) }
        if status < 0 { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
