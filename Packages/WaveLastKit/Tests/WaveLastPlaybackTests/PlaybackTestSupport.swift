// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

@testable import WaveLastCore
@testable import WaveLastPlayback

/// Records what the controller asks the engine to do; tests push events back.
@MainActor
final class FakeEngine: PlayerEngine {
    var onEvent: ((EngineEvent) -> Void)?
    var currentTime: TimeInterval = 0
    private(set) var loaded: [(PlayableItem, Bool)] = []
    private(set) var calls: [String] = []

    func load(_ item: PlayableItem, autoplay: Bool) {
        loaded.append((item, autoplay))
        calls.append("load")
    }
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func seek(to time: TimeInterval) { calls.append("seek \(Int(time))"); currentTime = time }
    func stop() { calls.append("stop") }

    func emit(_ e: EngineEvent) { onEvent?(e) }

    /// Simulates AVPlayer becoming ready and starting.
    func startPlaying(duration: TimeInterval = 200) {
        emit(.ready(duration: duration))
        emit(.playing)
    }

    /// Simulates `seconds` of continuous playback in 0.5 s ticks from `from`.
    func tick(from: TimeInterval, seconds: TimeInterval) {
        var t = from
        while t <= from + seconds {
            emit(.time(t))
            t += 0.5
        }
    }
}

/// Resolves tracks to file URLs, optionally failing or delaying some.
struct FakeSource: SourceProvider {
    let id: SourceID
    let displayName = "Fake"
    let capabilities: SourceCapabilities = []
    var failing: Set<String> = []
    var delays: [String: UInt64] = [:]

    init(id: SourceID = .local, failing: Set<String> = [], delays: [String: UInt64] = [:]) {
        self.id = id
        self.failing = failing
        self.delays = delays
    }

    func search(_ query: String) async throws -> [Track] { [] }

    func resolve(_ track: Track) async throws -> PlayableItem {
        if let d = delays[track.id] { try await Task.sleep(nanoseconds: d) }
        if failing.contains(track.id) { throw SourceError.trackNotFound }
        return PlayableItem(url: URL(fileURLWithPath: "/tmp/\(track.id).m4a"))
    }
}

@MainActor
final class RecordingScrobbler: ScrobbleSink {
    var nowPlayingIDs: [String] = []
    var scrobbledIDs: [String] = []
    func nowPlaying(_ track: Track) { nowPlayingIDs.append(track.id) }
    func scrobble(_ track: Track, startedAt: Date) { scrobbledIDs.append(track.id) }
}

func makeTrack(_ n: Int, duration: TimeInterval? = 200, source: SourceID = .local) -> Track {
    Track(
        id: "t\(n)", title: "Track \(n)", artist: "Artist \(n)", album: "Album", duration: duration,
        source: source, location: .localFile(relativePath: "Music/t\(n).m4a"))
}

func podcastTrack(_ id: String = "ep") -> Track {
    Track(
        id: id, title: "Episode", artist: "Host", album: "Show", duration: 3600, source: .podcast,
        location: .podcastEpisode(
            feedURL: URL(string: "https://e.com/f")!, episodeGUID: id,
            enclosureURL: URL(string: "https://cdn.e.com/\(id).mp3")!))
}

/// Waits for pending resolve tasks (they hop through the main actor).
@MainActor
func settle(_ times: Int = 20) async {
    for _ in 0..<times { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<times { await Task.yield() }
}

/// Writes a short mono 16-bit PCM WAV of silence. Used instead of bundling
/// third-party audio in the repository.
func writeWAV(to url: URL, seconds: Double = 1.0, sampleRate: Int = 44_100) throws {
    let frames = Int(Double(sampleRate) * seconds)
    let dataBytes = frames * 2
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
    d.append(Data(count: dataBytes))
    try d.write(to: url)
}

func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
