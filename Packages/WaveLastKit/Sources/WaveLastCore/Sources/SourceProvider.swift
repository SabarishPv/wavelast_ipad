// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

public struct SourceCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let search = SourceCapabilities(rawValue: 1 << 0)
    public static let streaming = SourceCapabilities(rawValue: 1 << 1)
    public static let offline = SourceCapabilities(rawValue: 1 << 2)
}

public enum SourceError: Error, Equatable, Sendable {
    case notConfigured(String)
    case trackNotFound
    case wrongSource
    case network(NetworkError)
    case unsupported(String)

    public var userMessage: String {
        switch self {
        case .notConfigured(let what): return "\(what) isn't set up yet. Open Settings to configure it."
        case .trackNotFound: return "This track is no longer available."
        case .wrongSource: return "This track belongs to a different source."
        case .network(let e): return e.userMessage
        case .unsupported(let why): return why
        }
    }
}

/// A place music comes from. Each provider turns its own tracks into
/// something AVFoundation can play. New legitimate sources (documented APIs
/// or open protocols) are added by implementing this protocol and registering
/// the provider; the player itself does not change.
public protocol SourceProvider: Sendable {
    var id: SourceID { get }
    var displayName: String { get }
    var capabilities: SourceCapabilities { get }

    /// Searches this source. Sources without `.search` return [].
    func search(_ query: String) async throws -> [Track]
    /// Turns a track owned by this source into a playable URL.
    func resolve(_ track: Track) async throws -> PlayableItem
}

/// Looks providers up by `SourceID`.
public struct SourceRegistry: Sendable {
    private var providers: [SourceID: any SourceProvider] = [:]

    public init(_ providers: [any SourceProvider] = []) {
        for p in providers { register(p) }
    }

    public mutating func register(_ provider: any SourceProvider) {
        providers[provider.id] = provider
    }

    public mutating func unregister(_ id: SourceID) { providers[id] = nil }

    public func provider(for id: SourceID) -> (any SourceProvider)? { providers[id] }

    public var all: [any SourceProvider] {
        providers.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func resolve(_ track: Track) async throws -> PlayableItem {
        guard let p = providers[track.source] else {
            throw SourceError.notConfigured(track.source.rawValue.capitalized)
        }
        return try await p.resolve(track)
    }
}

/// Plays podcast enclosures directly. Resume position is applied by the
/// player from the persistence layer, not here.
public struct PodcastSource: SourceProvider {
    public let id: SourceID = .podcast
    public let displayName = "Podcasts"
    public let capabilities: SourceCapabilities = [.streaming]

    public init() {}

    public func search(_ query: String) async throws -> [Track] { [] }

    public func resolve(_ track: Track) async throws -> PlayableItem {
        guard case .podcastEpisode(_, _, let url) = track.location else { throw SourceError.wrongSource }
        return PlayableItem(url: url)
    }
}

/// Plays files in the app's library folder.
public struct LocalFileSource: SourceProvider {
    public let id: SourceID = .local
    public let displayName = "On This iPad"
    public let capabilities: SourceCapabilities = [.offline]
    public let libraryRoot: URL

    public init(libraryRoot: URL) { self.libraryRoot = libraryRoot }

    public func search(_ query: String) async throws -> [Track] { [] }

    public func resolve(_ track: Track) async throws -> PlayableItem {
        guard case .localFile(let rel) = track.location else { throw SourceError.wrongSource }
        let url = libraryRoot.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SourceError.trackNotFound }
        return PlayableItem(url: url)
    }
}
