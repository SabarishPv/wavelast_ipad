// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors
//
// Derived from LastWave-Native `data/music/TextMatch.kt`
// (https://github.com/Clash-Projects/LastWave-Native, GPL-3.0,
// Copyright (C) LastWave authors / Clash-Projects contributors).
// Ported to Swift and reduced to the normalisation + scoring used by local
// library search and LRCLIB result selection.

import Foundation

public enum TextMatch {
    static let variantWords: Set<String> = [
        "live", "remix", "karaoke", "cover", "instrumental", "slowed", "sped", "nightcore",
        "acoustic", "demo", "edit", "remaster", "remastered", "mono", "stereo",
        "version", "deluxe", "bonus", "mix", "extended", "radio", "clean", "explicit",
        "original", "orchestral", "unplugged", "rerecorded", "anniversary", "edition",
    ]

    /// Lowercases (locale-independent), strips diacritics from Latin letters
    /// only, applies compatibility composition, folds Arabic letter variants,
    /// and collapses everything that is not a letter, number or mark to single
    /// spaces. Non-Latin scripts keep their marks (Hindi matras, Thai vowels).
    public static func normalize(_ value: String) -> String {
        let lower = value.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let decomposed = lower.decomposedStringWithCanonicalMapping
        var stripped = String.UnicodeScalarView()
        var previousWasLatinBase = false
        for scalar in decomposed.unicodeScalars {
            let isMark =
                scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark
                || scalar.properties.generalCategory == .enclosingMark
            if isMark && previousWasLatinBase { continue }
            stripped.append(scalar)
            if !isMark {
                previousWasLatinBase = (scalar.isASCII && scalar.properties.isAlphabetic)
            }
        }
        let composed = String(stripped).precomposedStringWithCompatibilityMapping
        let folded = foldArabic(composed)

        var out = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            let cat = scalar.properties.generalCategory
            let isWordChar: Bool
            switch cat {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .decimalNumber, .letterNumber, .otherNumber,
                .nonspacingMark, .spacingMark, .enclosingMark:
                isWordChar = true
            default:
                isWordChar = false
            }
            if isWordChar {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    private static func foldArabic(_ s: String) -> String {
        var r = s
        for v in ["أ", "إ", "آ", "ٱ"] { r = r.replacingOccurrences(of: v, with: "ا") }
        r = r.replacingOccurrences(of: "ؤ", with: "و")
        r = r.replacingOccurrences(of: "ئ", with: "ي")
        r = r.replacingOccurrences(of: "ة", with: "ه")
        return r
    }

    /// Normalised words of a string.
    public static func words(_ value: String) -> [String] {
        normalize(value).split(separator: " ").map(String.init)
    }

    /// True when every word of `query` is a prefix of some word in `text`.
    /// Used for library search ("beat it" matches "Beat It (Single Version)").
    public static func matches(query: String, in text: String) -> Bool {
        let q = words(query)
        guard !q.isEmpty else { return true }
        let t = words(text)
        return q.allSatisfy { qw in t.contains { $0.hasPrefix(qw) } }
    }

    /// 0...1 similarity between a wanted title/artist/duration and a candidate.
    /// Penalises variant words (live, remix…) the user did not ask for.
    public static func matchScore(
        wantedTitle: String, wantedArtist: String, wantedDuration: TimeInterval?,
        candidateTitle: String, candidateArtist: String, candidateDuration: TimeInterval?
    ) -> Double {
        let wt = Set(words(wantedTitle)), ct = Set(words(candidateTitle))
        let wa = Set(words(wantedArtist)), ca = Set(words(candidateArtist))
        func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
            if a.isEmpty && b.isEmpty { return 1 }
            let u = a.union(b).count
            return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
        }
        var score = 0.6 * jaccard(wt, ct) + 0.3 * jaccard(wa, ca)
        if let w = wantedDuration, let c = candidateDuration, w > 0, c > 0 {
            let diff = abs(w - c)
            score += diff <= 2 ? 0.1 : (diff <= 6 ? 0.05 : 0)
            if diff > 15 { score -= 0.2 }
        } else {
            score += 0.05
        }
        let unexpectedVariants = ct.subtracting(wt).intersection(variantWords)
        score -= 0.15 * Double(unexpectedVariants.count)
        return max(0, min(1, score))
    }
}
