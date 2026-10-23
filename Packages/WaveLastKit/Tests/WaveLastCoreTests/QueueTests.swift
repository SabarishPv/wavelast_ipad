// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing

@testable import WaveLastCore

@Suite("Playback queue")
struct QueueTests {
    func titles(_ q: PlaybackQueue) -> [String] { q.entries.map(\.track.title) }

    @Test func startsAtRequestedIndexAndClampsInvalidIndex() {
        let q = PlaybackQueue(tracks: (1...3).map { makeTrack($0) }, startAt: 1)
        #expect(q.current?.track.id == "t2")
        #expect(PlaybackQueue(tracks: (1...3).map { makeTrack($0) }, startAt: 9).currentIndex == 0)
        #expect(PlaybackQueue(tracks: [], startAt: 0).currentIndex == nil)
    }

    @Test func appendAndPlayNext() {
        var q = PlaybackQueue(tracks: [makeTrack(1), makeTrack(2)])
        q.append([makeTrack(3)])
        q.playNext([makeTrack(9)])
        #expect(titles(q) == ["Track 1", "Track 9", "Track 2", "Track 3"])
        #expect(q.current?.track.id == "t1")
        #expect(q.upNext.map(\.track.id) == ["t9", "t2", "t3"])
    }

    @Test func addingToEmptyQueueSelectsFirst() {
        var q = PlaybackQueue()
        q.playNext([makeTrack(1)])
        #expect(q.current?.track.id == "t1")
        var q2 = PlaybackQueue()
        q2.append([makeTrack(5), makeTrack(6)])
        #expect(q2.currentIndex == 0)
    }

    @Test func sameTrackCanBeQueuedTwiceAndRemovedIndividually() {
        var q = PlaybackQueue(tracks: [makeTrack(1)])
        let added = q.append([makeTrack(1)])
        #expect(q.entries.count == 2)
        q.remove(ids: [added[0].id])
        #expect(q.entries.count == 1)
        #expect(q.currentIndex == 0)
    }

    @Test func removingEntriesBeforeCurrentKeepsCurrent() {
        var q = PlaybackQueue(tracks: (1...5).map { makeTrack($0) }, startAt: 3)
        q.remove(ids: [q.entries[0].id, q.entries[1].id])
        #expect(q.current?.track.id == "t4")
        #expect(q.currentIndex == 1)
    }

    @Test func removingCurrentSelectsNextSurvivor() {
        var q = PlaybackQueue(tracks: (1...5).map { makeTrack($0) }, startAt: 2)
        // Remove an earlier entry, the current one and the one after it.
        q.remove(ids: [q.entries[0].id, q.entries[2].id, q.entries[3].id])
        #expect(q.current?.track.id == "t5")
    }

    @Test func removingLastCurrentFallsBackToPrevious() {
        var q = PlaybackQueue(tracks: (1...3).map { makeTrack($0) }, startAt: 2)
        q.remove(ids: [q.entries[2].id])
        #expect(q.current?.track.id == "t2")
    }

    @Test func removingEverythingClearsCurrent() {
        var q = PlaybackQueue(tracks: (1...2).map { makeTrack($0) })
        q.remove(atOffsets: IndexSet(0..<2))
        #expect(q.isEmpty)
        #expect(q.current == nil)
    }

    @Test(arguments: [
        (IndexSet([0]), 3, ["Track 2", "Track 3", "Track 1", "Track 4"]),
        (IndexSet([3]), 0, ["Track 4", "Track 1", "Track 2", "Track 3"]),
        (IndexSet([0, 2]), 4, ["Track 2", "Track 4", "Track 1", "Track 3"]),
        (IndexSet([1]), 1, ["Track 1", "Track 2", "Track 3", "Track 4"]),
    ])
    func moveFollowsSwiftUISemantics(source: IndexSet, dest: Int, expected: [String]) {
        var q = PlaybackQueue(tracks: (1...4).map { makeTrack($0) }, startAt: 0)
        q.move(fromOffsets: source, toOffset: dest)
        #expect(titles(q) == expected)
        #expect(q.current?.track.id == "t1", "current entry must follow the move")
    }

    @Test func advanceAndRepeatModes() {
        var q = PlaybackQueue(tracks: (1...2).map { makeTrack($0) })
        let r1 = q.advance()
        #expect(r1)
        let r2 = q.advance()
        #expect(!r2, "end of queue with repeat off")
        q.repeatMode = .all
        let r3 = q.advance()
        #expect(r3)
        #expect(q.current?.track.id == "t1")
        q.repeatMode = .one
        let r4 = q.advance(userInitiated: false)
        #expect(r4)
        #expect(q.current?.track.id == "t1", "repeat-one replays automatically")
        let r5 = q.advance(userInitiated: true)
        #expect(r5)
        #expect(q.current?.track.id == "t2", "pressing Next leaves repeat-one track")
    }

    @Test func goBackWrapsOnlyWithRepeatAll() {
        var q = PlaybackQueue(tracks: (1...3).map { makeTrack($0) })
        let r6 = q.goBack()
        #expect(!r6)
        q.repeatMode = .all
        let r7 = q.goBack()
        #expect(r7)
        #expect(q.current?.track.id == "t3")
    }

    @Test func shuffleKeepsCurrentFirstAndRestoresOrder() {
        var rng = SeededRNG(state: 42)
        var q = PlaybackQueue(tracks: (1...10).map { makeTrack($0) }, startAt: 4)
        let original = titles(q)
        q.setShuffle(true, using: &rng)
        #expect(q.isShuffled)
        #expect(q.currentIndex == 0)
        #expect(q.current?.track.id == "t5")
        #expect(Set(titles(q)) == Set(original))
        #expect(titles(q) != original)

        q.advance()
        let nowPlaying = q.current!.track.id
        q.playNext([makeTrack(99)])
        q.setShuffle(false, using: &rng)
        #expect(!q.isShuffled)
        #expect(q.current?.track.id == nowPlaying, "turning shuffle off keeps the current track")
        var expected = original
        let anchor = expected.firstIndex(of: q.current!.track.title)! + 1
        expected.insert("Track 99", at: anchor)
        #expect(titles(q) == expected)
    }

    @Test func shuffleIsDeterministicWithSeed() {
        var a = SeededRNG(state: 7), b = SeededRNG(state: 7)
        var q1 = PlaybackQueue(tracks: (1...20).map { makeTrack($0) })
        var q2 = q1
        q1.setShuffle(true, using: &a)
        q2.setShuffle(true, using: &b)
        #expect(titles(q1) == titles(q2))
    }

    @Test func codableRoundTripPreservesEverything() throws {
        var rng = SeededRNG(state: 1)
        var q = PlaybackQueue(tracks: (1...5).map { makeTrack($0) }, startAt: 2)
        q.repeatMode = .all
        q.setShuffle(true, using: &rng)
        let data = try JSONEncoder().encode(q)
        var decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
        #expect(decoded == q)
        decoded.setShuffle(false, using: &rng)
        #expect(decoded.entries.map(\.track.id) == ["t1", "t2", "t3", "t4", "t5"])
    }
}

@Suite("Playback state machine")
struct StateMachineTests {
    @Test func normalLifecycle() {
        var m = PlaybackStateMachine()
        let r8 = m.handle(.load)
        #expect(r8)
        let r9 = m.handle(.loaded(autoplay: true))
        #expect(r9)
        #expect(m.status == .playing)
        let r10 = m.handle(.stall)
        #expect(r10)
        #expect(m.status == .buffering)
        let r11 = m.handle(.resume)
        #expect(r11)
        let r12 = m.handle(.pause)
        #expect(r12)
        #expect(m.status == .paused)
        let r13 = m.handle(.play)
        #expect(r13)
        let r14 = m.handle(.finish)
        #expect(r14)
        #expect(m.status == .ended)
        let r15 = m.handle(.play)
        #expect(r15)
        #expect(m.status == .playing)
    }

    @Test func rejectsIllegalTransitions() {
        var m = PlaybackStateMachine()
        let r16 = m.handle(.play)
        #expect(!r16, "nothing loaded")
        let r17 = m.handle(.finish)
        #expect(!r17)
        let r18 = m.handle(.resume)
        #expect(!r18)
        #expect(m.status == .idle)
    }

    @Test func failureAndStopFromAnyState() {
        var m = PlaybackStateMachine()
        m.handle(.load)
        let f = PlaybackFailure(.network, "x")
        let r19 = m.handle(.fail(f))
        #expect(r19)
        #expect(m.status == .failed(f))
        let r20 = m.handle(.stop)
        #expect(r20)
        #expect(m.status == .idle)
    }

    @Test func finishWhilePausedEnds() {
        var m = PlaybackStateMachine()
        m.handle(.load)
        m.handle(.loaded(autoplay: false))
        let r21 = m.handle(.finish)
        #expect(r21)
        #expect(m.status == .ended)
    }
}
