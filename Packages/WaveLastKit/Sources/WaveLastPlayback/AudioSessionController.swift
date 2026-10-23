// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

#if os(iOS)
    import AVFoundation

    /// Configures the shared AVAudioSession for music playback and translates its
    /// notifications into `AudioSessionEvent`s.
    ///
    /// Background playback also requires `UIBackgroundModes = [audio]` in
    /// Info.plist; `BackgroundAudioConfiguration.validate` checks that at launch.
    @MainActor
    public final class AudioSessionController {
        private let session: AVAudioSession
        private let center: NotificationCenter
        private var observers: [NSObjectProtocol] = []
        public var onEvent: ((AudioSessionEvent) -> Void)?

        public init(session: AVAudioSession = .sharedInstance(), center: NotificationCenter = .default) {
            self.session = session
            self.center = center
        }

        /// `.playback` keeps audio running with the screen locked and the
        /// Ring/Silent switch on silent. `.longFormAudio` lets AirPlay route it.
        public func configure() throws {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        }

        public func activate() throws { try session.setActive(true) }

        public func startObserving() {
            stopObserving()
            observers.append(
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                    guard let event = Self.event(fromInterruption: note) else { return }
                    MainActor.assumeIsolated { self?.onEvent?(event) }
                })
            observers.append(
                center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                    let event = Self.event(fromRouteChange: note)
                    MainActor.assumeIsolated { self?.onEvent?(event) }
                })
            observers.append(
                center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onEvent?(.mediaServicesReset) }
                })
        }

        public func stopObserving() {
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        nonisolated static func event(fromInterruption note: Notification) -> AudioSessionEvent? {
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return nil }
            switch type {
            case .began:
                return .interruptionBegan
            case .ended:
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
                return .interruptionEnded(shouldResume: opts.contains(.shouldResume))
            @unknown default:
                return nil
            }
        }

        nonisolated static func event(fromRouteChange note: Notification) -> AudioSessionEvent {
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            switch AVAudioSession.RouteChangeReason(rawValue: raw) {
            case .oldDeviceUnavailable: return .routeChanged(.oldDeviceUnavailable)
            case .newDeviceAvailable: return .routeChanged(.newDeviceAvailable)
            default: return .routeChanged(.other)
            }
        }
    }
#endif

/// Checks the app's Info.plist declares background audio. Without it iOS
/// suspends the app (and stops the music) shortly after the screen locks.
public enum BackgroundAudioConfiguration {
    public static func validate(infoDictionary: [String: Any]?) -> Bool {
        (infoDictionary?["UIBackgroundModes"] as? [String])?.contains("audio") == true
    }
}
