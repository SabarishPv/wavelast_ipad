// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

public struct LyricLine: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    /// Seconds from track start.
    public let time: TimeInterval
    public let text: String
}

public enum Lyrics: Equatable, Sendable {
    /// Time-synchronised lines, sorted by time.
    case synced([LyricLine])
    /// Plain text with no timing.
    case plain(String)
    /// The track is marked instrumental by the provider.
    case instrumental

    /// Index of the line that should be highlighted at `time`, or nil before
    /// the first line. Binary search: called every display frame.
    public static func activeLineIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

/// Parser for the LRC format, including:
/// - several timestamps on one line (`[00:12.00][01:30.00]chorus`)
/// - `[offset:+/-ms]` (positive offset shows lyrics earlier, per the LRC spec)
/// - minutes over 59, 1–3 fractional digits, and `mm:ss:xx` variants
/// - metadata tags (`[ar:]`, `[ti:]`…) which are ignored
/// - enhanced word tags (`<00:12.30>`) which are stripped
public enum LRCParser {
    public static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var raw: [(TimeInterval, String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                if let t = parseTimestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let v = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(v) { offset = ms / 1000 }
                }
                line = line[line.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let lyric = stripWordTags(String(line)).trimmingCharacters(in: .whitespaces)
            for t in times { raw.append((t, lyric)) }
        }

        // Stable sort by time keeps file order for equal timestamps.
        let sorted = raw.enumerated().sorted { a, b in
            a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0
        }.map(\.element)
        return sorted.enumerated().map { i, item in
            LyricLine(index: i, time: max(0, item.0 - offset), text: item.1)
        }
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, `mm:ss:xx`.
    static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
            let minutes = Int(parts[0]), minutes >= 0
        else { return nil }
        var secondsPart = parts[1]
        var fraction: Substring = ""
        if parts.count == 3 {
            fraction = parts[2]
        } else if let dot = secondsPart.firstIndex(of: ".") {
            fraction = secondsPart[secondsPart.index(after: dot)...]
            secondsPart = secondsPart[..<dot]
        }
        guard let seconds = Int(secondsPart), (0..<60).contains(seconds),
            fraction.count <= 3, fraction.allSatisfy(\.isNumber)
        else { return nil }
        let frac = fraction.isEmpty ? 0 : Double("0." + fraction)!
        return Double(minutes * 60 + seconds) + frac
    }

    static func stripWordTags(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">"),
                parseTimestamp(s[s.index(after: i)..<close]) != nil
            {
                i = s.index(after: close)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
