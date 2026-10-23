// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing

@testable import WaveLastCore
@testable import WaveLastPlayback

@MainActor
@Suite("Playback controller")
struct PlaybackControllerTests {
    let engine = FakeEngine()
    let store = try! LibraryStore.inMemory()

    func controller(_ source: FakeSource = FakeSource(), extra: [any SourceProvider] = []) -> PlaybackController {
        PlaybackController(engine: engine, sources: SourceRegistry([source] + extra), store: store)
    }

    @Test func playLoadsResolvesAndBecomesPlaying() async {
        let c = controller()
        c.play([makeTrack(1), makeTrack(2)])
        #expect(c.status == .loading)
        await settle(c)
        #expect(engine.loaded.count == 1)
        #expect(engine.loaded[0].0.url.lastPathComponent == "t1.m4a")
        #expect(engine.loaded[0].1 == true, "autoplay")
        engine.startPlaying(duration: 180)
        #expect(c.status == .playing)
        #expect(c.duration == 180)
        #expect(c.isPlaying)
    }

    @Test func finishingAdvancesAndEndOfQueueEnds() async {
        let c = controller()
        c.play([makeTrack(1), makeTrack(2)])
        await settle(c)
        engine.startPlaying()
        engine.emit(.finished)
        await settle(c)
        #expect(c.currentTrack?.id == "t2")
        #expect(engine.loaded.count == 2)
        engine.startPlaying()
        engine.emit(.finished)
        await settle(c)
        #expect(c.status == .ended)
        #expect(c.currentTrack?.id == "t2", "stays on the last track")
    }

    @Test func repeatOneReplaysSameTrack() async {
        let c = controller()
        c.play([makeTrack(1), makeTrack(2)])
        c.setRepeat(.one)
        await settle(c)
        engine.startPlaying()
        engine.emit(.finished)
        await settle(c)
        #expect(c.currentTrack?.id == "t1")
        #expect(engine.loaded.count == 2)
    }

    @Test func pauseResumeAndToggle() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying()
        c.togglePlayPause()
        #expect(engine.calls.last == "pause")
        engine.emit(.paused)
        #expect(c.status == .paused)
        c.togglePlayPause()
        #expect(engine.calls.last == "play")
        engine.emit(.playing)
        #expect(c.status == .playing)
    }

    @Test func bufferingStallAndRecovery() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying()
        engine.emit(.stalled)
        #expect(c.status == .buffering)
        #expect(c.isPlaying, "buffering still counts as playing for the UI")
        engine.emit(.playing)
        #expect(c.status == .playing)
    }

    @Test func previousRestartsWhenPastThreshold() async {
        let c = controller()
        c.play([makeTrack(1), makeTrack(2)], startAt: 1)
        await settle(c)
        engine.startPlaying()
        engine.emit(.time(10))
        c.previous()
        #expect(c.currentTrack?.id == "t2")
        #expect(engine.calls.last == "seek 0")
        engine.emit(.time(1))
        c.previous()
        await settle(c)
        #expect(c.currentTrack?.id == "t1")
    }

    @Test func staleResolveIsIgnored() async {
        // t1's resolve is held open; the user skips to t2 meanwhile. When t1's
        // resolve finally returns it must be discarded, not loaded.
        let gate = ResolveGate()
        let c = controller(FakeSource(gates: ["t1": gate]))
        c.play([makeTrack(1), makeTrack(2)])
        for _ in 0..<10 { await Task.yield() }
        c.next()
        await settle(c)
        #expect(engine.loaded.map(\.0.url.lastPathComponent) == ["t2.m4a"])
        gate.release()
        let dropped = await waitUntil { c.droppedStaleResults == 1 }
        #expect(dropped, "the late t1 result must reach the generation guard and be dropped")
        #expect(engine.loaded.map(\.0.url.lastPathComponent) == ["t2.m4a"], "t1 must never be loaded after t2 was chosen")
        #expect(c.currentTrack?.id == "t2")
    }

    @Test func brokenTracksAreSkippedButNotForever() async {
        let c = controller(FakeSource(failing: ["t1", "t2"]))
        c.play([makeTrack(1), makeTrack(2), makeTrack(3)])
        await settle(c)
        #expect(c.currentTrack?.id == "t3")
        #expect(engine.loaded.count == 1)

        let engine2 = FakeEngine()
        let c2 = PlaybackController(engine: engine2, sources: SourceRegistry([FakeSource(failing: ["t1", "t2", "t3", "t4"])]), store: nil)
        c2.play((1...4).map { makeTrack($0) })
        await settle(c2)
        if case .failed(let f) = c2.status {
            #expect(f.kind == .fileMissing)
        } else {
            Issue.record("expected failed status, got \(c2.status)")
        }
        #expect(c2.currentTrack?.id == "t3", "stops after \(PlaybackController.maxAutoSkips) consecutive failures")
        #expect(c2.lastError != nil)
    }

    @Test func engineFailureIsReported() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.emit(.failed(PlaybackFailure(.unsupportedFormat, "nope")))
        #expect(c.status == .failed(PlaybackFailure(.unsupportedFormat, "nope")))
        #expect(c.lastError == "nope")
    }

    @Test func missingSourceGivesClearError() async {
        let c = controller()
        c.play([Track(id: "s", title: "s", artist: "", source: .subsonic, location: .subsonic(songID: "1"))])
        await settle(c)
        #expect(c.lastError?.contains("isn't set up") == true)
    }

    @Test func queueEditsWhilePlaying() async {
        let c = controller()
        c.play([makeTrack(1), makeTrack(2)])
        await settle(c)
        engine.startPlaying()
        c.playNext([makeTrack(5)])
        c.addToQueue([makeTrack(6)])
        #expect(c.queue.entries.map(\.track.id) == ["t1", "t5", "t2", "t6"])
        c.moveInQueue(fromOffsets: [3], toOffset: 1)
        #expect(c.queue.entries.map(\.track.id) == ["t1", "t6", "t5", "t2"])
        #expect(engine.loaded.count == 1, "editing upcoming items doesn't interrupt playback")

        // Removing the playing entry moves on to the next one.
        c.removeFromQueue(ids: [c.queue.entries[0].id])
        await settle(c)
        #expect(c.currentTrack?.id == "t6")
        #expect(engine.loaded.count == 2)
        c.removeFromQueue(ids: Set(c.queue.entries.map(\.id)))
        #expect(c.status == .idle)
        #expect(c.currentTrack == nil)
    }

    @Test func addingToEmptyQueueStartsPlayback() async {
        let c = controller()
        c.addToQueue([makeTrack(1)])
        await settle(c)
        #expect(engine.loaded.count == 1)
    }

    @Test func selectingQueueEntryPlaysIt() async {
        let c = controller()
        c.play((1...3).map { makeTrack($0) })
        await settle(c)
        c.select(entryID: c.queue.entries[2].id)
        await settle(c)
        #expect(engine.loaded.last?.0.url.lastPathComponent == "t3.m4a")
    }

    @Test func queueIsPersistedAndRestoredPaused() async throws {
        let c = controller()
        c.play((1...3).map { makeTrack($0) }, startAt: 1)
        await settle(c)
        engine.startPlaying()
        engine.emit(.time(30))
        c.pause()

        let engine2 = FakeEngine()
        let c2 = PlaybackController(engine: engine2, sources: SourceRegistry([FakeSource()]), store: store)
        c2.restore()
        await settle(c2)
        #expect(c2.currentTrack?.id == "t2")
        #expect(engine2.loaded.first?.1 == false, "restored queue must not start playing by itself")
        #expect(engine2.loaded.first?.0.startPosition == 30)
    }

    @Test func pressingPlayWhileLoadingStartsWhenReady() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        c.pause()  // user changes mind during load…
        c.resume()  // …and back again
        engine.emit(.ready(duration: 100))
        #expect(engine.calls.suffix(1) == ["play"])
    }

    @Test func pausingWhileLoadingKeepsItPaused() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        c.pause()
        engine.emit(.ready(duration: 100))
        #expect(engine.calls.last == "pause")
        #expect(c.status == .paused)
    }

    @Test func historyAndNowPlayingRecordedOncePerTrack() async throws {
        let c = controller()
        let s = RecordingScrobbler()
        c.scrobbler = s
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying()
        engine.emit(.paused)
        engine.emit(.playing)
        #expect(try store.history().map(\.track.id) == ["t1"])
        #expect(s.nowPlayingIDs == ["t1"])
    }

    @Test func scrobblesAfterHalfTheTrackButNotForSeeks() async {
        let c = controller()
        let s = RecordingScrobbler()
        c.scrobbler = s
        c.play([makeTrack(1, duration: 100), makeTrack(2, duration: 100)])
        await settle(c)
        engine.startPlaying(duration: 100)
        // Seek straight to the end: jumping does not count as listening.
        engine.emit(.time(0))
        engine.emit(.time(95))
        #expect(s.scrobbledIDs.isEmpty)
        engine.tick(from: 0, seconds: 49)
        #expect(s.scrobbledIDs.isEmpty)
        engine.tick(from: 49.5, seconds: 2)
        #expect(s.scrobbledIDs == ["t1"])
        engine.tick(from: 52, seconds: 40)
        #expect(s.scrobbledIDs == ["t1"], "only once per play")
    }

    @Test func pausedTimeDoesNotCountTowardsScrobble() async {
        let c = controller()
        let s = RecordingScrobbler()
        c.scrobbler = s
        c.play([makeTrack(1, duration: 100)])
        await settle(c)
        engine.startPlaying(duration: 100)
        engine.emit(.paused)
        engine.tick(from: 0, seconds: 90)
        #expect(s.scrobbledIDs.isEmpty)
    }

    @Test func podcastProgressIsSavedAndResumed() async throws {
        let c = controller(FakeSource(), extra: [FakeSource(id: .podcast)])
        c.play([podcastTrack("ep1")])
        await settle(c)
        engine.startPlaying(duration: 3600)
        engine.tick(from: 0, seconds: 25)
        c.pause()
        let saved = try #require(try store.progress(episodeKey: "ep1"))
        #expect(saved.position >= 24)

        let engine2 = FakeEngine()
        let c2 = PlaybackController(engine: engine2, sources: SourceRegistry([FakeSource(id: .podcast)]), store: store)
        c2.play([podcastTrack("ep1")])
        await settle(c2)
        #expect((engine2.loaded.first?.0.startPosition ?? 0) >= 24, "episode resumes where it stopped")
    }

    @Test func finishedPodcastIsMarkedCompleted() async throws {
        let c = controller(FakeSource(), extra: [FakeSource(id: .podcast)])
        c.play([podcastTrack("ep2")])
        await settle(c)
        engine.startPlaying(duration: 3600)
        engine.emit(.finished)
        #expect(try store.progress(episodeKey: "ep2")?.completed == true)
    }

    @Test func interruptionPausesAndResumesOnlyIfPlaying() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying()
        c.handleAudioSession(.interruptionBegan)
        #expect(engine.calls.last == "pause")
        engine.emit(.paused)
        c.handleAudioSession(.interruptionEnded(shouldResume: true))
        #expect(engine.calls.last == "play")
        engine.emit(.playing)

        // Interrupted while the user had paused: do not start playing afterwards.
        c.pause()
        engine.emit(.paused)
        let before = engine.calls.count
        c.handleAudioSession(.interruptionBegan)
        c.handleAudioSession(.interruptionEnded(shouldResume: true))
        #expect(!engine.calls.dropFirst(before).contains("play"))
    }

    @Test func headphonesUnpluggedPauses() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying()
        c.handleAudioSession(.routeChanged(.newDeviceAvailable))
        #expect(engine.calls.last != "pause")
        c.handleAudioSession(.routeChanged(.oldDeviceUnavailable))
        #expect(engine.calls.last == "pause")
    }

    @Test func mediaServicesResetReloadsCurrentTrack() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying()
        engine.emit(.time(42))
        c.handleAudioSession(.mediaServicesReset)
        await settle(c)
        #expect(engine.loaded.count == 2)
        #expect(engine.loaded.last?.0.startPosition == 42)
        #expect(engine.loaded.last?.1 == false)
    }

    @Test func remoteCommands() async {
        let c = controller()
        #expect(c.handleRemote(.play) == false, "nothing to play")
        c.play([makeTrack(1), makeTrack(2)])
        await settle(c)
        engine.startPlaying()
        #expect(c.handleRemote(.pause))
        #expect(engine.calls.last == "pause")
        #expect(c.handleRemote(.seek(50)))
        #expect(engine.calls.last == "seek 50")
        #expect(c.handleRemote(.next))
        #expect(c.currentTrack?.id == "t2")
    }

    @Test func seekIsClampedToDuration() async {
        let c = controller()
        c.play([makeTrack(1)])
        await settle(c)
        engine.startPlaying(duration: 100)
        c.seek(to: 500)
        #expect(engine.calls.last == "seek 100")
        c.seek(to: -3)
        #expect(engine.calls.last == "seek 0")
    }
}
