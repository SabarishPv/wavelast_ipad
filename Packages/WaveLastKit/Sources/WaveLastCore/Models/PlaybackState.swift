// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// Player status as seen by the UI.
public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    /// Waiting for network data while the user wants playback.
    case buffering
    case ended
    case failed(PlaybackFailure)

    public var isActive: Bool {
        switch self {
        case .playing, .buffering, .loading: return true
        default: return false
        }
    }
}

public struct PlaybackFailure: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case sourceUnavailable
        case network
        case unsupportedFormat
        case fileMissing
        case decoding
        case unknown
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Events that drive the state machine.
public enum PlaybackEvent: Equatable, Sendable {
    case load
    case loaded(autoplay: Bool)
    case play
    case pause
    case stall
    case resume
    case finish
    case fail(PlaybackFailure)
    case stop
}

/// A small, explicit state machine so illegal transitions are caught in tests
/// instead of surfacing as a stuck play button.
public struct PlaybackStateMachine: Equatable, Sendable {
    public private(set) var status: PlaybackStatus = .idle

    public init() {}

    /// Applies an event. Returns false (and leaves state unchanged) when the
    /// event is not valid in the current state.
    @discardableResult
    public mutating func handle(_ event: PlaybackEvent) -> Bool {
        guard let next = Self.transition(from: status, on: event) else { return false }
        status = next
        return true
    }

    public static func transition(from status: PlaybackStatus, on event: PlaybackEvent) -> PlaybackStatus? {
        switch (status, event) {
        case (_, .stop): return .idle
        case (_, .load): return .loading
        case (_, .fail(let f)): return .failed(f)
        case (.loading, .loaded(let autoplay)): return autoplay ? .playing : .paused
        case (.paused, .play), (.ended, .play), (.buffering, .play): return .playing
        case (.loading, .play): return .loading
        case (.playing, .pause), (.buffering, .pause), (.loading, .pause): return .paused
        case (.playing, .stall): return .buffering
        case (.buffering, .resume): return .playing
        // AVPlayer may report "paused" a moment before the end notification.
        case (.playing, .finish), (.buffering, .finish), (.paused, .finish): return .ended
        case (.playing, .play), (.paused, .pause): return status
        default: return nil
        }
    }
}
