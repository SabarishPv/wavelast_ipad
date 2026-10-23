// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

public struct Recommendation: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { "\(artist)\u{1F}\(title)" }
    public var title: String
    public var artist: String
    public var score: Double
    /// Seed tracks that led to this suggestion (for "Because you played…").
    public var becauseOf: [String]
}

/// Ranks Last.fm `track.getSimilar` results from several seeds.
/// A candidate suggested by more seeds ranks higher; tracks the user already
/// has (or played recently) are removed; one artist can't dominate the list.
public enum RecommendationRanker {
    public static func rank(
        similarBySeed: [(seed: String, similar: [LastFMSimilarTrack])],
        exclude known: Set<String>,
        maxPerArtist: Int = 3,
        limit: Int = 50
    ) -> [Recommendation] {
        var acc: [String: Recommendation] = [:]
        for (seed, list) in similarBySeed {
            for s in list {
                let key = Self.key(artist: s.artist, title: s.title)
                guard !known.contains(key) else { continue }
                if var r = acc[key] {
                    r.score += s.match
                    if !r.becauseOf.contains(seed) { r.becauseOf.append(seed) }
                    acc[key] = r
                } else {
                    acc[key] = Recommendation(title: s.title, artist: s.artist, score: s.match, becauseOf: [seed])
                }
            }
        }
        // Bonus for agreement between seeds.
        let scored = acc.values.map { r -> Recommendation in
            var r = r
            r.score *= 1 + 0.25 * Double(r.becauseOf.count - 1)
            return r
        }
        var perArtist: [String: Int] = [:]
        var out: [Recommendation] = []
        for r in scored.sorted(by: { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }) {
            let a = TextMatch.normalize(r.artist)
            guard perArtist[a, default: 0] < maxPerArtist else { continue }
            perArtist[a, default: 0] += 1
            out.append(r)
            if out.count == limit { break }
        }
        return out
    }

    public static func key(artist: String, title: String) -> String {
        TextMatch.normalize(artist) + "\u{1F}" + TextMatch.normalize(title)
    }
}
