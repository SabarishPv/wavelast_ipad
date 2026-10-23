// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// Where a track's audio lives. Each case is owned by one `SourceProvider`.
public enum TrackLocation: Codable, Hashable, Sendable {
    /// A file copied into the app's library folder. Stored as a path relative
    /// to the library root so the app container can move between installs.
    case localFile(relativePath: String)
    /// A podcast episode enclosure.
    case podcastEpisode(feedURL: URL, episodeGUID: String, enclosureURL: URL)
    /// A song on a user-configured Subsonic-compatible server.
    case subsonic(songID: String)
}

/// The identifier of the source that can resolve a track to playable audio.
public struct SourceID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let local: SourceID = "local"
    public static let podcast: SourceID = "podcast"
    public static let subsonic: SourceID = "subsonic"
}

public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds. `nil` when unknown (e.g. a stream that has not loaded yet).
    public var duration: TimeInterval?
    public var trackNumber: Int?
    public var source: SourceID
    public var location: TrackLocation
    /// Relative path (local) or remote URL string of cover art, if any.
    public var artworkRef: String?

    public init(
        id: String,
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        source: SourceID,
        location: TrackLocation,
        artworkRef: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.source = source
        self.location = location
        self.artworkRef = artworkRef
    }

    /// Display-safe title (never empty).
    public var displayTitle: String { title.isEmpty ? "Unknown Title" : title }
    /// Display-safe artist (never empty).
    public var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
}

/// Something the player can load. Sources must express any authentication
/// in the URL itself (as Subsonic token auth does): AVPlayer has no public
/// API for custom request headers.
public struct PlayableItem: Hashable, Sendable {
    public var url: URL
    /// Position to start at (e.g. resumed podcast progress).
    public var startPosition: TimeInterval

    public init(url: URL, startPosition: TimeInterval = 0) {
        self.url = url
        self.startPosition = startPosition
    }
}
