// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WaveLastCore

/// Audio formats WaveLast imports. These are the containers/codecs
/// AVFoundation decodes on iPadOS. Ogg, Opus-in-WebM, WMA and APE are not
/// supported by Apple's frameworks and are reported as unsupported instead of
/// being imported and failing later.
public enum SupportedAudioFormats {
    public static let extensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "aifc", "caf"]
    public static let knownUnsupported: Set<String> = ["ogg", "oga", "opus", "webm", "wma", "ape", "wv", "mka", "dsf", "dff"]
    public static let lyricsExtensions: Set<String> = ["lrc"]

    /// Types offered in the Files picker.
    public static var contentTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in ["flac", "caf", "m4b", "aac", "lrc"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    public static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

public struct ImportResult: Equatable, Sendable {
    public var imported: [Track] = []
    public var duplicates: [String] = []
    public var unsupported: [String] = []
    public var failed: [String: String] = [:]
    public var lyricsFiles: [String] = []
}

/// Copies picked files into the app's library folder and reads their metadata.
/// Copying (rather than bookmarking) means files keep playing after the user
/// moves or deletes the original, and works for iCloud Drive / external drives
/// that are not always connected.
public struct LocalImporter: Sendable {
    public let libraryRoot: URL

    public init(libraryRoot: URL) { self.libraryRoot = libraryRoot }

    public var musicFolder: URL { libraryRoot.appendingPathComponent("Music", isDirectory: true) }
    public var artworkFolder: URL { libraryRoot.appendingPathComponent("Artwork", isDirectory: true) }
    public var lyricsFolder: URL { libraryRoot.appendingPathComponent("Lyrics", isDirectory: true) }

    /// Imports files. `existingIDs` lets duplicates be skipped without a DB lookup.
    public func importFiles(_ urls: [URL], existingIDs: Set<String>) async -> ImportResult {
        var result = ImportResult()
        let fm = FileManager.default
        for dir in [musicFolder, artworkFolder, lyricsFolder] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var seen = existingIDs
        for url in urls {
            let name = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()

            if SupportedAudioFormats.lyricsExtensions.contains(ext) {
                let dest = lyricsFolder.appendingPathComponent(
                    Self.lyricsKey(forBaseName: url.deletingPathExtension().lastPathComponent) + ".lrc")
                do {
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: url, to: dest)
                    result.lyricsFiles.append(name)
                } catch {
                    result.failed[name] = error.localizedDescription
                }
                continue
            }
            guard SupportedAudioFormats.isSupported(url) else {
                result.unsupported.append(name)
                continue
            }
            var copiedTo: URL?
            do {
                let hash = try Self.sha256(of: url)
                let id = "local:\(hash.prefix(32))"
                if seen.contains(id) {
                    result.duplicates.append(name)
                    continue
                }
                let rel = "Music/\(hash.prefix(32)).\(ext)"
                let dest = libraryRoot.appendingPathComponent(rel)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: url, to: dest)
                    copiedTo = dest
                }
                var (track, artwork) = try await Self.readMetadata(
                    of: dest, id: id, relativePath: rel, originalName: url.deletingPathExtension().lastPathComponent)
                if let artwork {
                    let artRel = "Artwork/\(hash.prefix(32)).img"
                    try artwork.write(to: libraryRoot.appendingPathComponent(artRel))
                    track.artworkRef = artRel
                }
                result.imported.append(track)
                seen.insert(id)
            } catch {
                // Never keep a copy of a file that couldn't be imported.
                if let copiedTo { try? fm.removeItem(at: copiedTo) }
                result.failed[name] = error.localizedDescription
            }
        }
        return result
    }

    /// Reads title/artist/album/duration/artwork with AVFoundation. Falls back
    /// to "Artist - Title" parsed from the file name.
    static func readMetadata(of url: URL, id: String, relativePath: String, originalName: String) async throws -> (Track, Data?) {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
            guard try await asset.load(.isPlayable) else { throw PlaybackFailure(.unsupportedFormat, "") }
        } catch {
            throw PlaybackFailure(.unsupportedFormat, "This file can't be played on iPad (unsupported or damaged).")
        }
        var title: String?, artist: String?, album: String?, artwork: Data?
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: title = try? await item.load(.stringValue)
            case .commonKeyArtist: artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: album = try? await item.load(.stringValue)
            case .commonKeyArtwork: artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        let parsed = parseFileName(originalName)
        let seconds = duration.isNumeric && duration.seconds > 0 ? duration.seconds : nil
        let track = Track(
            id: id,
            title: title?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? parsed.title,
            artist: artist?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? parsed.artist ?? "",
            album: album ?? "",
            duration: seconds,
            source: .local,
            location: .localFile(relativePath: relativePath))
        return (track, artwork)
    }

    /// "Artist - Title" → (artist, title); "01 Title" → (nil, "Title").
    public static func parseFileName(_ name: String) -> (artist: String?, title: String) {
        var base = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if let r = base.range(of: #"^\d{1,3}[\s.\-]+"#, options: .regularExpression) { base.removeSubrange(r) }
        let parts = base.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty { return (artist, title) }
        }
        return (nil, base.isEmpty ? name : base)
    }

    /// Key used to pair an imported `.lrc` with a track: normalised "artist title".
    public static func lyricsKey(forBaseName base: String) -> String {
        let p = parseFileName(base)
        let raw = [p.artist ?? "", p.title].joined(separator: " ")
        let n = TextMatch.normalize(raw).replacingOccurrences(of: " ", with: "_")
        return n.isEmpty ? "untitled" : n
    }

    public static func lyricsKey(for track: Track) -> String {
        let n = TextMatch.normalize("\(track.artist) \(track.title)").replacingOccurrences(of: " ", with: "_")
        return n.isEmpty ? "untitled" : n
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension PlaybackFailure: LocalizedError {
    public var errorDescription: String? { message }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
