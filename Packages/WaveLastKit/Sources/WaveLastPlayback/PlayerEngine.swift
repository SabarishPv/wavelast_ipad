// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import AVFoundation
import Foundation
import WaveLastCore

public enum EngineEvent: Equatable, Sendable {
    case ready(duration: TimeInterval?)
    case playing
    case paused
    case stalled
    case finished
    case failed(PlaybackFailure)
    case time(TimeInterval)
}

/// The audio backend the controller drives. `AVPlayerEngine` is the real one;
/// tests use a fake so playback logic runs without audio hardware.
@MainActor
public protocol PlayerEngine: AnyObject {
    var onEvent: ((EngineEvent) -> Void)? { get set }
    var currentTime: TimeInterval { get }
    func load(_ item: PlayableItem, autoplay: Bool)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

/// AVPlayer-backed engine. Plays any format AVFoundation supports on iPadOS
/// (AAC, ALAC, MP3, FLAC, WAV/AIFF/CAF, HLS). It does not play Ogg/WebM/Opus
/// containers or DASH; the importer rejects those up front.
@MainActor
public final class AVPlayerEngine: PlayerEngine {
    public var onEvent: ((EngineEvent) -> Void)?
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var rateObservation: NSKeyValueObservation?
    private var endObservers: [NSObjectProtocol] = []
    private var pendingAutoplay = false
    private var pendingStart: TimeInterval = 0

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) {
            [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.isNumeric else { return }
                self.onEvent?(.time(t.seconds))
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            let waiting = p.reasonForWaitingToPlay
            Task { @MainActor in
                guard let self, self.player.currentItem?.status == .readyToPlay else { return }
                switch status {
                case .playing: self.onEvent?(.playing)
                case .paused: self.onEvent?(.paused)
                case .waitingToPlayAtSpecifiedRate:
                    if waiting == .toMinimizeStalls || waiting == .evaluatingBufferingRate { self.onEvent?(.stalled) }
                @unknown default: break
                }
            }
        }
    }

    public var currentTime: TimeInterval {
        let t = player.currentTime()
        return t.isNumeric ? t.seconds : 0
    }

    public func load(_ item: PlayableItem, autoplay: Bool) {
        clearItemObservers()
        pendingAutoplay = autoplay
        pendingStart = item.startPosition
        let playerItem = AVPlayerItem(url: item.url)
        itemObservations.append(
            playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
                let status = it.status
                let error = it.error
                Task { @MainActor in self?.itemStatusChanged(status, error: error, item: it) }
            })
        endObservers.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.finished) }
            })
        endObservers.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main
            ) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated { self?.onEvent?(.failed(Self.failure(from: err))) }
            })
        player.replaceCurrentItem(with: playerItem)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: Error?, item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            let d = item.duration
            let duration: TimeInterval? = (d.isNumeric && d.seconds > 0) ? d.seconds : nil
            if pendingStart > 0 {
                player.seek(to: CMTime(seconds: pendingStart, preferredTimescale: 600))
                pendingStart = 0
            }
            onEvent?(.ready(duration: duration))
            if pendingAutoplay { player.play() }
        case .failed:
            onEvent?(.failed(Self.failure(from: error)))
        default:
            break
        }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func stop() {
        player.pause()
        clearItemObservers()
        player.replaceCurrentItem(with: nil)
    }

    private func clearItemObservers() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers.removeAll()
    }

    nonisolated static func failure(from error: Error?) -> PlaybackFailure {
        guard let ns = error as NSError? else { return PlaybackFailure(.unknown, "Playback failed.") }
        if ns.domain == NSURLErrorDomain {
            return PlaybackFailure(.network, "Couldn't load audio: \(ns.localizedDescription)")
        }
        if ns.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: ns.code) {
            case .fileFormatNotRecognized, .decoderNotFound, .formatUnsupported, .contentIsUnavailable:
                return PlaybackFailure(.unsupportedFormat, "This audio format isn't supported on iPad.")
            case .fileFailedToParse, .decodeFailed:
                return PlaybackFailure(.decoding, "The file appears to be damaged.")
            default: break
            }
        }
        return PlaybackFailure(.unknown, ns.localizedDescription)
    }
}
