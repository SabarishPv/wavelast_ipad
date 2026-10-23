# Implementation plan

Based on `reports/android-to-ipad-feasibility.md` in the planning workspace: native Swift and SwiftUI, a clean player with no unofficial streaming, and GPL-3.0.

## Repository and branches

- **Destination:** `SabarishPv/wavelast_ipad`. It is new, public and not a fork, so it inherits no LastWave-Desktop history.
- **`main`:** one initial commit with `LICENSE`, `README.md` and `.gitignore`, so pull requests have a base.
- **`feature/wavelast-ipad-v1`:** all implementation work, in reviewable commits. CI runs on pushes to this branch and on pull requests.
- **Never pushed to:** either Clash-Projects repository.

## Architecture

```
WaveLast (iOS app, SwiftUI)
  AppModel (composition root) → PlaybackController, LibraryStore, LocalImporter, LyricsService,
                                LastFMScrobbler, NowPlayingController, AudioSessionController
WaveLastPlayback (Swift package target)
  PlayerEngine protocol ← AVPlayerEngine
  PlaybackController: queue + state machine + resolve(generation guard) + history/scrobble/progress
WaveLastCore (Swift package target, Foundation-only)
  Models, PlaybackQueue, PlaybackStateMachine, SourceProvider/SourceRegistry
  HTTPClient (timeouts, retry, error mapping), LRCLIB, Last.fm, Podcasts (RSS), Subsonic
  SQLite persistence with versioned migrations
```

- **Source providers:** Local files, Podcasts and Subsonic. New providers are added by implementing `SourceProvider`.
- **Minimum OS:** iPadOS 17 (Observation framework, `ContentUnavailableView`).
- **Dependencies:** Apple frameworks only.

## Stages

| # | Stage | State |
|---|---|---|
| 0 | Repository skeleton, licence, notices, CI workflow, config validation | Done locally; awaiting review before push |
| 1 | Core logic and persistence, with tests | Done; 84 tests pass locally |
| 2 | Playback engine, controller, audio session, Now Playing, import, lyrics service, scrobbler, with tests | Done; 50 tests pass locally |
| 3 | SwiftUI iPad interface | Written; **not yet compiled** (needs the iOS SDK in CI) |
| 4 | App and UI tests on the Simulator | Written; run in CI after push |
| 5 | First CI run → fix real failures from logs → re-run until green | After approval |
| 6 | Signing route chosen by the owner (see `docs/INSTALL.md`) | Owner decision |
| 7 | Physical-iPad checklist (`docs/FEATURES.md`) | Owner, with an installed build |

## CI cost

- **Runner:** GitHub-hosted `macos-26`, a standard runner. Standard runners are free for public repositories.
- **Not used:** larger runners, paid services and secrets.
- **Artifact retention:** 14 days, or 30 days for logs.
