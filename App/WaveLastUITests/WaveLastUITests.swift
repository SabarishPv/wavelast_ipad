// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import XCTest

/// Drives the app on an iPad simulator with a seeded, offline fixture library.
final class WaveLastUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        if let app, testRun?.hasSucceeded == false {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "failure-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openSidebar(_ id: String) {
        let item = element("sidebar.\(id)")
        if !item.waitForExistence(timeout: 5) {
            // Portrait / compact: show the sidebar first.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "sidebar item \(id)")
        item.tap()
    }

    func testLaunchShowsLibraryWithFixtures() {
        XCTAssertTrue(element("track.Morning Tide").waitForExistence(timeout: 10))
        XCTAssertTrue(element("track.Paper Planes").exists)
        attachScreenshot("library")
    }

    func testSidebarNavigationReachesEverySection() {
        for (id, title) in [
            ("playlists", "Playlists"), ("podcasts", "Podcasts"), ("discover", "Discover"),
            ("server", "Music Server"), ("history", "History"), ("settings", "Settings"), ("library", "Library"),
        ] {
            openSidebar(id)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "navigated to \(title)")
        }
        openSidebar("discover")
        XCTAssertTrue(app.staticTexts["Connect Last.fm"].waitForExistence(timeout: 5), "Discover explains it needs Last.fm")
        openSidebar("server")
        XCTAssertTrue(app.staticTexts["No music server"].waitForExistence(timeout: 5))
    }

    func testPlayTrackOpenNowPlayingAndControl() {
        let row = element("track.Morning Tide")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let mini = element("miniplayer.open")
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "mini player appears once something plays")
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "playback started")

        mini.tap()
        XCTAssertTrue(element("nowplaying.title").waitForExistence(timeout: 5))
        XCTAssertEqual(element("nowplaying.title").label, "Morning Tide")
        attachScreenshot("now-playing")

        element("nowplaying.playpause").tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5), "paused")

        element("nowplaying.next").tap()
        let title = element("nowplaying.title")
        // Library order is by artist then title: Glass Rooftops, Morning Tide, Paper Planes.
        let moved = NSPredicate(format: "label == %@", "Paper Planes")
        expectation(for: moved, evaluatedWith: title)
        waitForExpectations(timeout: 5)

        element("nowplaying.close").tap()
        XCTAssertTrue(element("miniplayer.open").waitForExistence(timeout: 5))
    }

    func testQueueShowsUpNextAndPlayNextInserts() {
        XCTAssertTrue(element("track.Morning Tide").waitForExistence(timeout: 10))
        element("track.Morning Tide").tap()
        XCTAssertTrue(element("miniplayer.open").waitForExistence(timeout: 10))

        // Long-press → Play Next on another song.
        element("track.Glass Rooftops").press(forDuration: 1.0)
        let playNext = app.buttons["Play Next"].firstMatch
        XCTAssertTrue(playNext.waitForExistence(timeout: 5))
        playNext.tap()

        element("miniplayer.open").tap()
        openPanel("Up Next")
        // Queue: Glass Rooftops, Morning Tide (current), Glass Rooftops (play next), Paper Planes.
        XCTAssertTrue(element("queue.row.2").waitForExistence(timeout: 5))
        XCTAssertTrue(element("queue.row.2").label.contains("Glass Rooftops"), "Play Next puts the song right after the current one")
        XCTAssertTrue(element("queue.row.3").label.contains("Paper Planes"))
        attachScreenshot("queue")
    }

    func testSyncedLyricsFromImportedLRC() {
        XCTAssertTrue(element("track.Morning Tide").waitForExistence(timeout: 10))
        element("track.Morning Tide").tap()
        XCTAssertTrue(element("miniplayer.open").waitForExistence(timeout: 10))
        element("miniplayer.open").tap()
        openPanel("Lyrics")
        XCTAssertTrue(app.staticTexts["First fixture line"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Second fixture line"].exists)
        XCTAssertTrue(app.staticTexts["Synced lyrics from Local .lrc file"].exists)
        attachScreenshot("lyrics")
    }

    func testPlaylistFromFixturesPlays() {
        openSidebar("playlists")
        let p = element("playlist.Fixture Mix")
        XCTAssertTrue(p.waitForExistence(timeout: 5))
        p.tap()
        XCTAssertTrue(app.navigationBars["Fixture Mix"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("track.Paper Planes").waitForExistence(timeout: 5))
        element("track.Paper Planes").tap()
        XCTAssertTrue(element("miniplayer.open").waitForExistence(timeout: 10))
    }

    func testLicenseNoticeIsReachable() {
        openSidebar("settings")
        let about = element("settings.about")
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        XCTAssertTrue(element("about.license").waitForExistence(timeout: 5))
        XCTAssertTrue(element("about.license").label.contains("GNU General Public License"))
    }

    func testPortraitLayoutStillWorks() {
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        attachScreenshot("portrait")
        openSidebar("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func openPanel(_ name: String) {
        let segment = app.segmentedControls.buttons[name]
        if segment.waitForExistence(timeout: 3) {
            segment.tap()
        } else {
            // Portrait: panels open from the bottom toolbar.
            let id = name == "Lyrics" ? "nowplaying.showLyrics" : "nowplaying.showQueue"
            XCTAssertTrue(element(id).waitForExistence(timeout: 5))
            element(id).tap()
        }
    }

    private func attachScreenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
