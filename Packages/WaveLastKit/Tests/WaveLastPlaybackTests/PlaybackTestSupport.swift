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
    var gates: [String: ResolveGate] = [:]

    init(id: SourceID = .local, failing: Set<String> = [], gates: [String: ResolveGate] = [:]) {
        self.id = id
        self.failing = failing
        self.gates = gates
    }

    func search(_ query: String) async throws -> [Track] { [] }

    func resolve(_ track: Track) async throws -> PlayableItem {
        if let g = gates[track.id] { await g.wait() }
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

/// Waits until the controller has no resolve in flight, then lets the
/// main actor run any follow-up work. Deterministic: no fixed sleeps.
@MainActor
func settle(_ c: PlaybackController) async {
    await c.waitForPendingResolve()
    for _ in 0..<10 { await Task.yield() }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

/// Holds a resolve until the test releases it. Deliberately ignores task
/// cancellation so tests exercise the controller's generation guard, not
/// just cooperative cancellation.
final class ResolveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                continuation = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
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
