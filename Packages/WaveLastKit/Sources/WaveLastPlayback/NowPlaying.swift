// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import MediaPlayer
import WaveLastCore

/// Builds the lock-screen / Control Center metadata dictionary. Pure, so the
/// exact keys and values are unit-tested.
public enum NowPlayingInfoBuilder {
    public static func info(
        track: Track, elapsed: TimeInterval, duration: TimeInterval?, isPlaying: Bool,
        queueIndex: Int?, queueCount: Int
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if let d = duration ?? track.duration, d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        if let i = queueIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = i
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }
        return info
    }
}

/// Remote-control commands (lock screen, Control Center, headphones, keyboard
/// media keys) the controller responds to.
public enum RemoteCommand: Equatable, Sendable {
    case play, pause, togglePlayPause, next, previous
    case seek(TimeInterval)
}

/// Publishes Now Playing info and wires MPRemoteCommandCenter.
@MainActor
public final class NowPlayingController {
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkCache: (key: String, artwork: MPMediaItemArtwork)?

    public init(infoCenter: MPNowPlayingInfoCenter = .default(), commandCenter: MPRemoteCommandCenter = .shared()) {
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
    }

    public func bind(_ handler: @escaping @MainActor (RemoteCommand) -> Bool) {
        unbind()
        func add(_ cmd: MPRemoteCommand, _ make: @escaping (MPRemoteCommandEvent) -> RemoteCommand?) {
            cmd.isEnabled = true
            let token = cmd.addTarget { event in
                guard let c = make(event) else { return .commandFailed }
                return MainActor.assumeIsolated { handler(c) } ? .success : .noActionableNowPlayingItem
            }
            targets.append((cmd, token))
        }
        add(commandCenter.playCommand) { _ in .play }
        add(commandCenter.pauseCommand) { _ in .pause }
        add(commandCenter.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(commandCenter.nextTrackCommand) { _ in .next }
        add(commandCenter.previousTrackCommand) { _ in .previous }
        add(commandCenter.changePlaybackPositionCommand) { e in
            (e as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
    }

    public func unbind() {
        for (cmd, token) in targets { cmd.removeTarget(token) }
        targets.removeAll()
    }

    public func update(_ info: [String: Any]?, artworkKey: String? = nil, artworkData: (() -> Data?)? = nil) {
        guard var info else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        #if canImport(UIKit)
            if let key = artworkKey {
                if artworkCache?.key != key, let data = artworkData?(), let image = UIImage(data: data) {
                    artworkCache = (key, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
                }
                if let art = artworkCache, art.key == key { info[MPMediaItemPropertyArtwork] = art.artwork }
            }
        #endif
        infoCenter.nowPlayingInfo = info
    }

    public var currentInfo: [String: Any]? { infoCenter.nowPlayingInfo }
}

#if canImport(UIKit)
    import UIKit
#endif
