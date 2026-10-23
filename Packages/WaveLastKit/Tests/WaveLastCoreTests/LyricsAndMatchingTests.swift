// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Testing

@testable import WaveLastCore

@Suite("LRC parsing and timing")
struct LRCParserTests {
    @Test func parsesFixtureWithOffsetMultiTimestampsAndWordTags() throws {
        let lines = LRCParser.parse(Fixture.string("sample.lrc"))
        // [offset:+500] shows every line 0.5 s earlier.
        let expected: [(TimeInterval, String)] = [
            (11.5, "First line"),
            (16.7, "Chorus line"),
            (20.6, "Word timed line"),
            (24.9, "Colon fraction line"),
            (61.845, "Three digit fraction"),
            (90.0, "Chorus line"),
            (179.5, ""),
        ]
        #expect(lines.count == expected.count)
        for (line, (t, text)) in zip(lines, expected) {
            #expect(abs(line.time - t) < 0.0001, "time for \(text)")
            #expect(line.text == text)
        }
        #expect(lines.map(\.index) == Array(0..<expected.count))
    }

    @Test(arguments: [
        ("00:00", 0.0), ("01:02.5", 62.5), ("01:02.50", 62.5), ("01:02.500", 62.5),
        ("100:00.00", 6000.0), ("00:05:25", 5.25),
    ])
    func timestamps(tag: String, seconds: TimeInterval) {
        #expect(LRCParser.parseTimestamp(Substring(tag)) == seconds)
    }

    @Test(arguments: ["ar:Someone", "00:60.00", "aa:bb", "00:01.1234", "-1:00", "", "00"])
    func rejectsInvalidTimestamps(tag: String) {
        #expect(LRCParser.parseTimestamp(Substring(tag)) == nil)
    }

    @Test func negativeOffsetDelaysLinesAndNeverGoesBelowZero() {
        let lines = LRCParser.parse("[offset:-1000]\n[00:00.20]a\n[00:05.00]b")
        #expect(lines.map(\.time) == [1.2, 6.0])
        let early = LRCParser.parse("[offset:2000]\n[00:01.00]a")
        #expect(early.first?.time == 0)
    }

    @Test func activeLineFollowsPlaybackTime() {
        let lines = LRCParser.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c")
        #expect(Lyrics.activeLineIndex(in: lines, at: 0) == nil)
        #expect(Lyrics.activeLineIndex(in: lines, at: 9.99) == nil)
        #expect(Lyrics.activeLineIndex(in: lines, at: 10) == 0)
        #expect(Lyrics.activeLineIndex(in: lines, at: 19.9) == 0)
        #expect(Lyrics.activeLineIndex(in: lines, at: 20) == 1)
        #expect(Lyrics.activeLineIndex(in: lines, at: 500) == 2)
        #expect(Lyrics.activeLineIndex(in: [], at: 5) == nil)
    }

    @Test func emptyOrTaglessInputGivesNoLines() {
        #expect(LRCParser.parse("").isEmpty)
        #expect(LRCParser.parse("just some words\nmore words").isEmpty)
    }
}

@Suite("Text matching")
struct TextMatchTests {
    @Test func normalisesCaseDiacriticsAndPunctuation() {
        #expect(TextMatch.normalize("  Café  del   Mar!!  ") == "cafe del mar")
        #expect(TextMatch.normalize("Beyoncé – Halo (Live)") == "beyonce halo live")
        #expect(TextMatch.normalize("ＡＢＣ１２３") == "abc123", "full-width forms fold")
    }

    @Test func keepsNonLatinScripts() {
        #expect(TextMatch.normalize("Кино — Группа крови") == "кино группа крови")
        #expect(TextMatch.normalize("तुम ही हो") == "तुम ही हो", "Hindi vowel signs are letters, not accents")
        #expect(TextMatch.normalize("أحبك") == "احبك")
    }

    @Test func queryMatchesWordPrefixes() {
        #expect(TextMatch.matches(query: "beat it", in: "Michael Jackson Beat It (Single Version)"))
        #expect(TextMatch.matches(query: "mich bea", in: "Michael Jackson Beat It"))
        #expect(!TextMatch.matches(query: "thriller", in: "Michael Jackson Beat It"))
        #expect(TextMatch.matches(query: "   ", in: "anything"))
    }

    @Test func scorePrefersStudioVersionAndCloseDuration() {
        let studio = TextMatch.matchScore(
            wantedTitle: "Song Title", wantedArtist: "The Band", wantedDuration: 200,
            candidateTitle: "Song Title", candidateArtist: "The Band", candidateDuration: 201)
        let live = TextMatch.matchScore(
            wantedTitle: "Song Title", wantedArtist: "The Band", wantedDuration: 200,
            candidateTitle: "Song Title (Live)", candidateArtist: "The Band", candidateDuration: 250)
        let other = TextMatch.matchScore(
            wantedTitle: "Song Title", wantedArtist: "The Band", wantedDuration: 200,
            candidateTitle: "Other", candidateArtist: "Someone", candidateDuration: 200)
        #expect(studio > 0.9)
        #expect(live < studio)
        #expect(other < 0.3)
    }
}

@Suite("Recommendations")
struct RecommendationTests {
    @Test func agreementRanksHigherAndKnownTracksExcluded() {
        let a = [LastFMSimilarTrack(title: "X", artist: "A", match: 0.6), LastFMSimilarTrack(title: "Y", artist: "B", match: 0.9)]
        let b = [LastFMSimilarTrack(title: "X", artist: "A", match: 0.5), LastFMSimilarTrack(title: "Known", artist: "C", match: 1.0)]
        let r = RecommendationRanker.rank(
            similarBySeed: [("s1", a), ("s2", b)],
            exclude: [RecommendationRanker.key(artist: "c", title: "KNOWN")])
        #expect(r.map(\.title) == ["X", "Y"])
        #expect(r.first?.becauseOf == ["s1", "s2"])
    }

    @Test func capsTracksPerArtist() {
        let many = (0..<10).map { LastFMSimilarTrack(title: "T\($0)", artist: "Same", match: 1 - Double($0) / 100) }
        let r = RecommendationRanker.rank(similarBySeed: [("s", many)], exclude: [], maxPerArtist: 3)
        #expect(r.count == 3)
        #expect(r.map(\.title) == ["T0", "T1", "T2"])
    }
}
