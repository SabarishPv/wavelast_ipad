// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import WaveLastCore

/// Sends now-playing updates and scrobbles to Last.fm.
/// Scrobbles are written to the database first and submitted in batches, so
/// listening offline (or while Last.fm is down) is not lost.
@MainActor
public final class LastFMScrobbler: ScrobbleSink {
    public typealias ClientFactory = () -> (LastFMClient, LastFMSession)?

    private let store: LibraryStore
    private let makeClient: ClientFactory
    private var flushTask: Task<Void, Never>?
    public private(set) var lastError: String?
    /// Called when Last.fm says the session is no longer valid.
    public var onSessionInvalid: (() -> Void)?

    public init(store: LibraryStore, makeClient: @escaping ClientFactory) {
        self.store = store
        self.makeClient = makeClient
    }

    public func nowPlaying(_ track: Track) {
        guard track.source != .podcast, let (client, session) = makeClient() else { return }
        let entry = Self.entry(for: track, startedAt: Date())
        Task {
            // Now-playing is best-effort; failures are not retried.
            try? await client.updateNowPlaying(entry, session: session)
        }
    }

    public func scrobble(_ track: Track, startedAt: Date) {
        guard track.source != .podcast, makeClient() != nil else { return }
        try? store.enqueueScrobble(Self.entry(for: track, startedAt: startedAt))
        flush()
    }

    /// Submits pending scrobbles. Safe to call often (e.g. when back online).
    public func flush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.submitPending()
            self?.flushTask = nil
        }
    }

    func submitPending() async {
        guard let (client, session) = makeClient() else { return }
        while let batch = try? store.pendingScrobbles(limit: 50), !batch.isEmpty {
            do {
                try await client.scrobble(batch.map(\.entry), session: session)
                try? store.removeScrobbles(ids: batch.map(\.id))
                lastError = nil
            } catch let e as LastFMAPIError {
                lastError = e.message
                if e.requiresReauthentication { onSessionInvalid?() }
                if !e.isTemporary && !e.requiresReauthentication {
                    // Permanently rejected (e.g. invalid parameters): drop so
                    // one bad entry cannot block the backlog forever.
                    try? store.removeScrobbles(ids: batch.map(\.id))
                    continue
                }
                return
            } catch let e as NetworkError {
                lastError = e.userMessage
                return  // keep for later
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    static func entry(for t: Track, startedAt: Date) -> ScrobbleEntry {
        ScrobbleEntry(
            artist: t.displayArtist, track: t.displayTitle, album: t.album.isEmpty ? nil : t.album,
            duration: t.duration, timestamp: Int(startedAt.timeIntervalSince1970))
    }
}
