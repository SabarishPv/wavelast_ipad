// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// Platform-neutral description of audio-session notifications, so the
/// decision logic can be unit-tested anywhere.
public enum AudioSessionEvent: Equatable, Sendable {
    /// Another app, a call, Siri or an alarm took the audio.
    case interruptionBegan
    /// The interruption ended. `shouldResume` is the system's hint.
    case interruptionEnded(shouldResume: Bool)
    /// Output route changed.
    case routeChanged(RouteChangeReason)
    /// The media server crashed and was restarted; all players must be rebuilt.
    case mediaServicesReset
}

public enum RouteChangeReason: Equatable, Sendable {
    /// Headphones unplugged / Bluetooth disconnected.
    case oldDeviceUnavailable
    case newDeviceAvailable
    case other
}

public enum AudioSessionAction: Equatable, Sendable {
    case none
    case pause
    case resume
    case rebuildPlayer
}

/// Decides what the player does for each audio-session event.
/// Rules follow Apple's guidance:
/// - pause when interrupted, and remember whether we were playing;
/// - resume after the interruption only if we were playing *and* the system
///   says resuming is appropriate;
/// - pause when the old output (e.g. headphones) disappears, never auto-play
///   when a new device appears.
public struct AudioSessionPolicy: Equatable, Sendable {
    public private(set) var wasPlayingBeforeInterruption = false

    public init() {}

    public mutating func handle(_ event: AudioSessionEvent, isPlaying: Bool) -> AudioSessionAction {
        switch event {
        case .interruptionBegan:
            wasPlayingBeforeInterruption = isPlaying || wasPlayingBeforeInterruption
            return isPlaying ? .pause : .none
        case .interruptionEnded(let shouldResume):
            defer { wasPlayingBeforeInterruption = false }
            return (shouldResume && wasPlayingBeforeInterruption) ? .resume : .none
        case .routeChanged(.oldDeviceUnavailable):
            return isPlaying ? .pause : .none
        case .routeChanged:
            return .none
        case .mediaServicesReset:
            wasPlayingBeforeInterruption = false
            return .rebuildPlayer
        }
    }
}
