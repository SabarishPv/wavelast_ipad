# WaveLast

A native iPad music player written in Swift and SwiftUI.

WaveLast plays music you own (imported from Files), podcasts (RSS), and songs from your own Subsonic‑compatible server. It adds synced lyrics (LRCLIB and `.lrc` files) and Last.fm scrobbling and recommendations through the official Last.fm API.

> **Status: early development (0.1.0).** It is built and tested in CI on the iPad **Simulator**. It has **not yet been verified on a physical iPad**. See [docs/FEATURES.md](docs/FEATURES.md) for what each test covers and [docs/INSTALL.md](docs/INSTALL.md) for installation options.

## Features

| Area | What it does |
|---|---|
| Library | Import MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF and CAF from Files. Files are copied into the app, de-duplicated by content, and read for metadata and artwork |
| Playback | AVFoundation playback with background audio, lock screen and Control Center controls, headphone and keyboard controls, and handling of interruptions and route changes |
| Queue | Play next, add, remove, reorder, shuffle (reversible) and repeat. The queue is restored after relaunch |
| Playlists and history | Stored in SQLite with versioned migrations |
| Lyrics | Imported `.lrc` files first, then [LRCLIB](https://lrclib.net). Lines are time-synced, and tapping a line seeks to it |
| Podcasts | Subscribe by RSS URL. Resume position and played state are saved |
| Last.fm | Desktop authorization flow (WaveLast never sees your password), now-playing updates, scrobbling with an offline backlog, and recommendations from `track.getSimilar` |
| Music server | Search and stream from Navidrome, Airsonic, Gonic and other Subsonic API servers, using token authentication |
| iPad | Sidebar layout, portrait and landscape, Split View, Slide Over and Stage Manager, hardware-keyboard shortcuts, pointer hover, and VoiceOver labels |

### Deliberately not included

WaveLast does **not** stream from YouTube or YouTube Music. It does not use add-ons that resolve Tidal or other subscription-service streams, Widevine or any other DRM code, Spotify cookie/token impersonation, private Apple Music endpoints, or unofficial Musixmatch access. These depend on services' private interfaces or on bypassing their access controls. See `reports/android-to-ipad-feasibility.md` in the planning workspace for the reasoning. New sources must use documented APIs or open protocols; see [Adding a source](#adding-a-source).

## Building

You don't need Xcode on your own Mac. Every push to the development branch runs [`.github/workflows/ipad-build.yml`](.github/workflows/ipad-build.yml) on a GitHub-hosted macOS runner. The workflow:

1. Validates the configuration and lints the code (`scripts/validate_config.sh`, `swift-format`).
2. Generates the Xcode project from [`project.yml`](project.yml) using XcodeGen (version pinned and checksum-verified).
3. Runs the package tests on macOS and on an iPad Simulator.
4. Builds the app and runs its unit and UI tests on an iPad Simulator.
5. Uploads logs, test results, the simulator app and an **unsigned** device IPA.

With Xcode 26 installed locally you can run the same steps:

```sh
xcodegen generate
xcodebuild test -project WaveLast.xcodeproj -scheme WaveLast -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)'
```

The core logic also builds and tests with only a Swift toolchain:

```sh
cd Packages/WaveLastKit && swift test
```

## Layout

```
App/WaveLast/            SwiftUI app (views, composition root, Info.plist, assets)
App/WaveLastTests/       XCTest on the iOS Simulator (audio session, Now Playing, Keychain)
App/WaveLastUITests/     XCUITest flows against a seeded offline fixture library
Packages/WaveLastKit/
  Sources/WaveLastCore/      models, queue, LRC, Last.fm, LRCLIB, RSS, Subsonic, SQLite
  Sources/WaveLastPlayback/  AVPlayer engine, controller, audio session, Now Playing, import
  Tests/                     Swift Testing suites with fixtures and mock network responses
scripts/                 CI helpers (config validation, simulator selection, icon generator)
docs/                    plan, features and verification, testing, licensing, installation
```

## Adding a source

Implement `SourceProvider` (`search` and `resolve` to a URL AVFoundation can play), then register it in `AppModel`. The player, queue, lyrics and scrobbling work unchanged. Sources must use documented APIs or open protocols and must not embed shared credentials.

## License

WaveLast is free software, licensed under the **GNU General Public License v3.0** (GPL-3.0-only). See [LICENSE](LICENSE).

Parts of the logic are adapted from [LastWave-Native](https://github.com/Clash-Projects/LastWave-Native) (GPL-3.0). See [NOTICE.md](NOTICE.md) and [docs/LICENSING.md](docs/LICENSING.md). WaveLast is an independent project. It is not affiliated with or endorsed by LastWave or Clash-Projects, and it does not use their name, logo or artwork. No code or assets come from the LastWave-Desktop repository, which has no license.
