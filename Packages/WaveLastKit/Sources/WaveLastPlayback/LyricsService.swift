// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import WaveLastCore

public enum LyricsSourceKind: String, Equatable, Sendable {
    case localFile = "Local .lrc file"
    case lrclib = "LRCLIB"
}

public enum LyricsLoadResult: Equatable, Sendable {
    case found(Lyrics, LyricsSourceKind)
    case notFound
    case failed(String)
}

/// Finds lyrics for a track: an imported `.lrc` file first, then LRCLIB.
/// Results are cached per track for the session.
public actor LyricsService {
    let lyricsFolder: URL
    let lrclib: LRCLIBClient?
    private var cache: [String: LyricsLoadResult] = [:]

    public init(lyricsFolder: URL, lrclib: LRCLIBClient?) {
        self.lyricsFolder = lyricsFolder
        self.lrclib = lrclib
    }

    public func lyrics(for track: Track) async -> LyricsLoadResult {
        if let hit = cache[track.id] { return hit }
        let result = await load(track)
        // Don't cache transient failures so "Try again" works.
        if case .failed = result {} else { cache[track.id] = result }
        return result
    }

    public func invalidate(trackID: String) { cache[trackID] = nil }

    private func load(_ track: Track) async -> LyricsLoadResult {
        let local = lyricsFolder.appendingPathComponent(LocalImporter.lyricsKey(for: track) + ".lrc")
        if let text = try? String(contentsOf: local, encoding: .utf8) {
            let lines = LRCParser.parse(text)
            if !lines.isEmpty { return .found(.synced(lines), .localFile) }
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { return .found(.plain(plain), .localFile) }
        }
        guard let lrclib, track.source != .podcast else { return .notFound }
        do {
            if let l = try await lrclib.lyrics(title: track.title, artist: track.artist, album: track.album, duration: track.duration) {
                return .found(l, .lrclib)
            }
            return .notFound
        } catch let e as NetworkError {
            return .failed(e.userMessage)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
