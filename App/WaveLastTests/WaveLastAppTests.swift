// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import AVFoundation
import MediaPlayer
import WaveLastCore
import WaveLastPlayback
import XCTest

@testable import WaveLast

/// Tests that need the real iOS runtime (simulator): AVAudioSession,
/// MPNowPlayingInfoCenter, Keychain and the built Info.plist.
@MainActor
final class WaveLastAppTests: XCTestCase {

    // MARK: Background audio configuration

    func testInfoPlistDeclaresBackgroundAudio() {
        XCTAssertTrue(
            BackgroundAudioConfiguration.validate(infoDictionary: Bundle.main.infoDictionary),
            "UIBackgroundModes must contain 'audio' or playback stops when the iPad locks")
    }

    func testInfoPlistSupportsIPadMultitasking() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["UIRequiresFullScreen"] as? Bool, false)
        let orientations = try XCTUnwrap(info["UISupportedInterfaceOrientations~ipad"] as? [String])
        XCTAssertEqual(Set(orientations).count, 4)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "WaveLast")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.sabarishpv.wavelast")
    }

    func testAudioSessionIsConfiguredForPlayback() throws {
        let controller = AudioSessionController()
        try controller.configure()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().routeSharingPolicy, .longFormAudio)
    }

    // MARK: Interruptions and route changes (real notification plumbing)

    func testInterruptionNotificationsAreTranslated() {
        let center = NotificationCenter()
        let controller = AudioSessionController(center: center)
        var events: [AudioSessionEvent] = []
        controller.onEvent = { events.append($0) }
        controller.startObserving()
        defer { controller.stopObserving() }

        center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        center.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        center.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        center.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue])
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(
            events,
            [
                .interruptionBegan,
                .interruptionEnded(shouldResume: true),
                .interruptionEnded(shouldResume: false),
                .routeChanged(.oldDeviceUnavailable),
                .routeChanged(.other),
                .mediaServicesReset,
            ])
    }

    func testMalformedInterruptionIsIgnored() {
        let center = NotificationCenter()
        let controller = AudioSessionController(center: center)
        var events: [AudioSessionEvent] = []
        controller.onEvent = { events.append($0) }
        controller.startObserving()
        defer { controller.stopObserving() }
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: ["junk": 1])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Now Playing

    func testNowPlayingInfoIsPublished() {
        let np = NowPlayingController()
        let t = Track(
            id: "1", title: "Song", artist: "Singer", album: "LP", duration: 120, source: .local,
            location: .localFile(relativePath: "x"))
        np.update(NowPlayingInfoBuilder.info(track: t, elapsed: 5, duration: 120, isPlaying: true, queueIndex: 0, queueCount: 1))
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Song")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 120)
        np.update(nil)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testRemoteCommandsAreRegistered() {
        let np = NowPlayingController()
        np.bind { _ in true }
        defer { np.unbind() }
        let cc = MPRemoteCommandCenter.shared()
        XCTAssertTrue(cc.playCommand.isEnabled)
        XCTAssertTrue(cc.pauseCommand.isEnabled)
        XCTAssertTrue(cc.nextTrackCommand.isEnabled)
        XCTAssertTrue(cc.changePlaybackPositionCommand.isEnabled)
    }

    // MARK: Secrets

    func testKeychainRoundTripAndDelete() {
        let store = KeychainStore(service: "io.github.sabarishpv.wavelast.tests.\(UUID().uuidString)")
        XCTAssertNil(store.string(for: "k"))
        store.set("value-1", for: "k")
        XCTAssertEqual(store.string(for: "k"), "value-1")
        store.set("value-2", for: "k")
        XCTAssertEqual(store.string(for: "k"), "value-2")
        store.set(nil, for: "k")
        XCTAssertNil(store.string(for: "k"))
    }

    // MARK: App model bootstrap

    func testUITestModeSeedsIsolatedLibrary() {
        let model = AppModel(isUITesting: true)
        XCTAssertEqual(model.tracks.count, 3)
        XCTAssertEqual(model.playlists.map(\.name), ["Fixture Mix"])
        XCTAssertNil(model.lastFMUser)
        XCTAssertFalse(model.subsonicConfigured)
        XCTAssertNil(model.startupProblem, model.startupProblem ?? "")
    }

    func testSubsonicSettingsRegisterAndRemoveSource() {
        let model = AppModel(isUITesting: true)
        model.saveSubsonic(SubsonicConfiguration(serverURL: URL(string: "https://music.example.com")!, username: "u", password: "p"))
        XCTAssertTrue(model.subsonicConfigured)
        XCTAssertNotNil(model.player.sources.provider(for: .subsonic))
        model.saveSubsonic(nil)
        XCTAssertFalse(model.subsonicConfigured)
        XCTAssertNil(model.player.sources.provider(for: .subsonic))
    }

    func testFixtureTrackPlaysThroughRealEngine() async throws {
        let model = AppModel(isUITesting: true)
        model.play(model.tracks)
        for _ in 0..<100 where !model.player.isPlaying {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.player.isPlaying, "status: \(model.player.status)")
        XCTAssertEqual(model.player.duration ?? 0, 30, accuracy: 0.1)
        model.player.pause()
    }
}
