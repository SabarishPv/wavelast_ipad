// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors
//
// The resolve-generation guard (a result is applied only if it still belongs
// to the selection that started it) follows the design of LastWave-Native
// `playback/resolve/PlaybackResolver.kt` and `StreamResolveCoordinator.kt`
// (https://github.com/Clash-Projects/LastWave-Native, GPL-3.0,
// Copyright (C) LastWave authors / Clash-Projects contributors).

import Foundation
import Observation
import WaveLastCore

/// Receives listening events for scrobbling. The app's implementation talks
/// to Last.fm; tests record calls.
@MainActor
public protocol ScrobbleSink: AnyObject {
    func nowPlaying(_ track: Track)
    func scrobble(_ track: Track, startedAt: Date)
}

/// Owns the queue and drives a `PlayerEngine`. All UI reads state from here.
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var queue = PlaybackQueue()
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public private(set) var lastError: String?

    public var currentTrack: Track? { queue.current?.track }
    public var isPlaying: Bool { status == .playing || status == .buffering }

    @ObservationIgnored private var machine = PlaybackStateMachine()
    @ObservationIgnored private var sessionPolicy = AudioSessionPolicy()
    @ObservationIgnored private let engine: PlayerEngine
    @ObservationIgnored public var sources: SourceRegistry
    @ObservationIgnored private let store: LibraryStore?
    @ObservationIgnored public weak var scrobbler: ScrobbleSink?
    @ObservationIgnored public var onNowPlayingChange: (() -> Void)?
    @ObservationIgnored private let now: () -> Date

    /// Incremented for every new selection; stale async results are dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var recordedPlay = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var lastProgressSave: TimeInterval = 0

    /// Skip to the next track automatically after this many failures in a row.
    public static let maxAutoSkips = 3
    /// "Previous" restarts the current track when past this point.
    public static let restartThreshold: TimeInterval = 3

    public init(engine: PlayerEngine, sources: SourceRegistry, store: LibraryStore?, now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.sources = sources
        self.store = store
        self.now = now
        engine.onEvent = { [weak self] in self?.handle($0) }
    }

    // MARK: Restore / persist

    /// Restores the last queue paused at its last position (never autoplays).
    public func restore() {
        guard let (q, position) = (try? store?.loadQueue()) ?? nil, q.current != nil else { return }
        queue = q
        startCurrent(autoplay: false, startAt: position)
    }

    private func persistQueue() {
        try? store?.saveQueue(queue, position: elapsed)
    }

    // MARK: Commands

    public func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue.replace(with: tracks, startAt: index)
        consecutiveFailures = 0
        startCurrent(autoplay: true)
        persistQueue()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    public func resume() {
        switch status {
        case .ended:
            seek(to: 0)
            engine.play()
        case .failed, .idle:
            if queue.current != nil { startCurrent(autoplay: true) }
        case .loading:
            // Will start when ready.
            pendingAutoplayOverride = true
        default:
            engine.play()
        }
    }

    @ObservationIgnored private var pendingAutoplayOverride: Bool?

    public func pause() {
        if status == .loading { pendingAutoplayOverride = false }
        engine.pause()
        saveProgressIfPodcast(force: true)
        persistQueue()
    }

    public func next() {
        guard queue.advance(userInitiated: true) else { return }
        consecutiveFailures = 0
        startCurrent(autoplay: true)
        persistQueue()
    }

    public func previous() {
        if elapsed > Self.restartThreshold || !queue.goBack() {
            seek(to: 0)
            return
        }
        consecutiveFailures = 0
        startCurrent(autoplay: true)
        persistQueue()
    }

    public func seek(to time: TimeInterval) {
        let t = max(0, min(time, duration ?? .greatestFiniteMagnitude))
        engine.seek(to: t)
        elapsed = t
        lastTick = t
        onNowPlayingChange?()
    }

    public func select(entryID: UUID) {
        guard queue.select(id: entryID) else { return }
        consecutiveFailures = 0
        startCurrent(autoplay: true)
        persistQueue()
    }

    public func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        persistQueue()
    }

    public func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        persistQueue()
    }

    // MARK: Queue editing

    public func playNext(_ tracks: [Track]) {
        let wasEmpty = queue.current == nil
        queue.playNext(tracks)
        if wasEmpty { startCurrent(autoplay: true) }
        persistQueue()
    }

    public func addToQueue(_ tracks: [Track]) {
        let wasEmpty = queue.current == nil
        queue.append(tracks)
        if wasEmpty { startCurrent(autoplay: true) }
        persistQueue()
    }

    public func removeFromQueue(ids: Set<UUID>) {
        let before = queue.current?.id
        queue.remove(ids: ids)
        if queue.current == nil {
            stop()
        } else if queue.current?.id != before {
            startCurrent(autoplay: isPlaying)
        }
        persistQueue()
    }

    public func moveInQueue(fromOffsets: IndexSet, toOffset: Int) {
        queue.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistQueue()
    }

    public func stop() {
        generation += 1
        resolveTask?.cancel()
        engine.stop()
        machine.handle(.stop)
        status = machine.status
        elapsed = 0
        duration = nil
        onNowPlayingChange?()
    }

    // MARK: Audio session

    public func handleAudioSession(_ event: AudioSessionEvent) {
        switch sessionPolicy.handle(event, isPlaying: isPlaying) {
        case .none: break
        case .pause: pause()
        case .resume: resume()
        case .rebuildPlayer:
            // The media server restarted: reload the current item where we were.
            if queue.current != nil { startCurrent(autoplay: false, startAt: elapsed) }
        }
    }

    public func handleRemote(_ command: RemoteCommand) -> Bool {
        guard queue.current != nil else { return false }
        switch command {
        case .play: resume()
        case .pause: pause()
        case .togglePlayPause: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .seek(let t): seek(to: t)
        }
        return true
    }

    // MARK: Loading

    private func startCurrent(autoplay: Bool, startAt: TimeInterval = 0) {
        generation += 1
        let gen = generation
        resolveTask?.cancel()
        pendingAutoplayOverride = nil
        resetListening()
        guard let track = queue.current?.track else {
            stop()
            return
        }
        machine.handle(.load)
        status = machine.status
        elapsed = startAt
        duration = track.duration
        lastError = nil
        onNowPlayingChange?()

        resolveTask = Task { [weak self, sources, store] in
            do {
                var item = try await sources.resolve(track)
                if startAt > 0 {
                    item.startPosition = startAt
                } else if track.source == .podcast, let p = try? store?.progress(episodeKey: track.id), !p.completed, p.position > 5 {
                    item.startPosition = p.position
                }
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                let play = self.pendingAutoplayOverride ?? autoplay
                self.engine.load(item, autoplay: play)
                if item.startPosition > 0 { self.elapsed = item.startPosition }
            } catch {
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                let failure: PlaybackFailure
                if let s = error as? SourceError {
                    failure = PlaybackFailure(s == .trackNotFound ? .fileMissing : .sourceUnavailable, s.userMessage)
                } else if let n = error as? NetworkError {
                    failure = PlaybackFailure(.network, n.userMessage)
                } else {
                    failure = PlaybackFailure(.unknown, error.localizedDescription)
                }
                self.fail(failure, autoplay: autoplay)
            }
        }
    }

    private func fail(_ failure: PlaybackFailure, autoplay: Bool) {
        machine.handle(.fail(failure))
        status = machine.status
        lastError = failure.message
        consecutiveFailures += 1
        onNowPlayingChange?()
        // Skip broken tracks during continuous playback, but never loop forever.
        if autoplay, consecutiveFailures < Self.maxAutoSkips, queue.advance(userInitiated: true) {
            startCurrent(autoplay: true)
        }
    }

    // MARK: Engine events

    func handle(_ event: EngineEvent) {
        switch event {
        case .ready(let d):
            if let d { duration = d }
            // Show "paused" until the engine reports it is actually playing.
            machine.handle(.loaded(autoplay: false))
            status = machine.status
            // The user pressed play/pause while the track was loading.
            if let wanted = pendingAutoplayOverride { wanted ? engine.play() : engine.pause() }
            pendingAutoplayOverride = nil
        case .playing:
            if status == .buffering { machine.handle(.resume) } else { machine.handle(.play) }
            status = machine.status
            consecutiveFailures = 0
            if !recordedPlay, let t = currentTrack {
                recordedPlay = true
                startedAt = now()
                try? store?.recordPlay(t, at: startedAt)
                scrobbler?.nowPlaying(t)
            }
        case .paused:
            if status == .playing || status == .buffering || status == .loading {
                machine.handle(.pause)
                status = machine.status
            }
            lastTick = nil
        case .stalled:
            if machine.handle(.stall) { status = machine.status }
        case .finished:
            saveProgressIfPodcast(force: true, completed: true)
            machine.handle(.finish)
            status = machine.status
            if queue.advance(userInitiated: false) {
                startCurrent(autoplay: true)
            }
            persistQueue()
        case .failed(let f):
            fail(f, autoplay: true)
        case .time(let t):
            accumulateListening(to: t)
            elapsed = t
            saveProgressIfPodcast(force: false)
        }
        onNowPlayingChange?()
    }

    // MARK: Listening time, scrobbles, podcast progress

    private func resetListening() {
        listened = 0
        lastTick = nil
        scrobbled = false
        recordedPlay = false
        lastProgressSave = 0
    }

    private func accumulateListening(to t: TimeInterval) {
        defer { lastTick = t }
        guard isPlaying, let last = lastTick else { return }
        let delta = t - last
        // Ignore seeks (big jumps) and backwards time.
        guard delta > 0, delta < 2.5 else { return }
        listened += delta
        if !scrobbled, let track = currentTrack,
            ScrobbleRules.shouldScrobble(duration: duration ?? track.duration, listened: listened)
        {
            scrobbled = true
            scrobbler?.scrobble(track, startedAt: startedAt)
        }
    }

    private func saveProgressIfPodcast(force: Bool, completed: Bool = false) {
        guard let t = currentTrack, t.source == .podcast else { return }
        guard force || abs(elapsed - lastProgressSave) >= 10 else { return }
        lastProgressSave = elapsed
        try? store?.saveProgress(episodeKey: t.id, position: completed ? 0 : elapsed, completed: completed, at: now())
    }

    /// Test hook: number of tracks the user listened past the scrobble point.
    var listenedSeconds: TimeInterval { listened }
}
