// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import WaveLastCore
import WaveLastPlayback

/// Deterministic content for UI tests (launched with `-UITestMode`).
/// Audio is generated silence, so no third-party media is in the repository,
/// and the app runs with an isolated temporary library and no network sources.
@MainActor
enum UITestFixtures {
    static func seed(into model: AppModel) {
        let root = model.importer.libraryRoot
        let music = model.importer.musicFolder
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: model.importer.lyricsFolder, withIntermediateDirectories: true)

        let specs: [(String, String, String, Double)] = [
            ("fixture-1", "Morning Tide", "Harbor Lights", 30),
            ("fixture-2", "Glass Rooftops", "Harbor Lights", 30),
            ("fixture-3", "Paper Planes", "Static Gardens", 30),
        ]
        var tracks: [Track] = []
        for (id, title, artist, seconds) in specs {
            let rel = "Music/\(id).wav"
            writeSilentWAV(to: root.appendingPathComponent(rel), seconds: seconds)
            tracks.append(
                Track(
                    id: "local:\(id)", title: title, artist: artist, album: "Fixtures",
                    duration: seconds, source: .local, location: .localFile(relativePath: rel)))
        }
        try? model.store.upsert(tracks)

        // Synced lyrics for the first track, stored the way an imported .lrc is.
        let lrc = "[00:00.00]First fixture line\n[00:01.50]Second fixture line\n[00:20.00]Late line"
        let key = LocalImporter.lyricsKey(for: tracks[0])
        try? lrc.write(to: model.importer.lyricsFolder.appendingPathComponent(key + ".lrc"), atomically: true, encoding: .utf8)

        if let p = try? model.store.createPlaylist(name: "Fixture Mix") {
            try? model.store.setPlaylistTracks(id: p.id, trackIDs: [tracks[2].id, tracks[0].id])
        }
    }

    static func writeSilentWAV(to url: URL, seconds: Double, sampleRate: Int = 22_050) {
        let frames = Int(Double(sampleRate) * seconds)
        let dataBytes = frames * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2);
        u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))
        try? d.write(to: url)
    }
}
