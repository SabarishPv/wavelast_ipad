# Features and verification status

The **Evidence** column records only what has actually been run. Update it whenever CI or device testing produces new evidence.

**Evidence levels**

- **L:** Package tests passed locally with `swift test` on macOS, using a Swift toolchain only. They exercise the same Swift code, but on the macOS SDK.
- **S:** Passed in GitHub Actions on an iPad Simulator.
- **D:** Verified by hand on a physical iPad.

| Feature | Implementation | Automated tests | Evidence |
|---|---|---|---|
| Queue: add, play next, remove, reorder, select | `PlaybackQueue`, `PlaybackController` | `QueueTests`, `PlaybackControllerTests.queueEditsWhilePlaying` | L |
| Shuffle (reversible, seeded), repeat off/all/one | `PlaybackQueue` | `QueueTests` | L |
| Playback state machine (load → play → pause → buffering → end, failures) | `PlaybackStateMachine` | `StateMachineTests` | L |
| Stale-resolve protection; skipping broken tracks (max 3 in a row) | `PlaybackController` | `staleResolveIsIgnored`, `brokenTracksAreSkippedButNotForever` | L |
| Real AVPlayer loads a local file and reports duration; decode failures reported | `AVPlayerEngine` | `AVPlayerEngineTests` | L |
| Import from Files: copy, content de-duplication, metadata, unsupported and corrupt files rejected and cleaned up | `LocalImporter` | `LocalImportTests` | L |
| Files picker UI and security-scoped access | `LibraryView` (`.fileImporter`) | none (system UI can't be driven by XCUITest) | needs D |
| Persistence: library, playlists, history, queue snapshot, podcast progress, scrobble backlog | `LibraryStore` | `PersistenceTests` | L |
| Database migrations (v1 → v2), rollback on failure, refusing newer schema | `Migrator`, `WaveLastSchema` | `PersistenceTests` | L |
| LRC parsing (offset, multi-stamp, word tags) and active-line timing | `LRCParser`, `Lyrics` | `LRCParserTests` | L |
| LRCLIB lookup with search fallback and best-match choice | `LRCLIBClient` | `LRCLIBTests` (fixtures) | L |
| Lyrics: local `.lrc` first, LRCLIB second, cached, retry after failure | `LyricsService` | `LyricsServiceTests` | L |
| Last.fm signing, auth flow, errors, scrobble batching | `LastFMSigner`, `LastFMClient` | `LastFMTests` (signature checked against an independent reference) | L |
| Scrobble rules (> 30 s; half or 4 min; seeks and paused time don't count) | `ScrobbleRules`, `PlaybackController` | `scrobbleRules`, `scrobblesAfterHalf…`, `pausedTime…` | L |
| Scrobble backlog: kept while offline, dropped only if Last.fm rejects it permanently, re-auth notice | `LastFMScrobbler` | `ScrobblerTests` | L |
| Last.fm recommendations ranking | `RecommendationRanker` | `RecommendationTests` | L |
| Podcast RSS parsing (iTunes tags, CDATA, durations, dates, non-audio skipped) | `PodcastFeedParser` | `PodcastTests` | L |
| Podcast resume and completion | `PlaybackController`, `LibraryStore` | `podcastProgressIsSavedAndResumed`, `finishedPodcastIsMarkedCompleted` | L |
| Subsonic token auth, search, stream URL, auth errors | `SubsonicClient`, `SubsonicSource` | `SubsonicTests` (token checked against the protocol's documented example) | L |
| Network timeouts, retry and backoff, 429 Retry-After, offline, invalid responses, cancellation | `HTTPClient` | `HTTPClientTests` | L |
| Interruptions and route changes (decision logic) | `AudioSessionPolicy`, `PlaybackController` | `AudioSessionPolicyTests`, `interruption…`, `headphones…`, `mediaServicesReset…` | L |
| Interruptions and route changes (AVAudioSession notification translation) | `AudioSessionController` | `WaveLastAppTests.testInterruptionNotificationsAreTranslated` | needs S |
| Background audio configuration (`UIBackgroundModes`, `.playback` category) | Info.plist, `AudioSessionController` | `validate_config.sh`, `WaveLastAppTests` | config check L; runtime needs S |
| Now Playing metadata and remote commands | `NowPlayingInfoBuilder`, `NowPlayingController` | `NowPlayingTests`; `WaveLastAppTests` | builder L; system center needs S |
| Keychain storage of credentials | `KeychainStore` | `WaveLastAppTests.testKeychainRoundTripAndDelete` | needs S |
| SwiftUI launch, sidebar navigation, play, Now Playing, queue, lyrics, playlist, licence screen, portrait | Views | `WaveLastUITests` | needs S |
| Hardware keyboard shortcuts, pointer hover | `PlaybackCommands`, `.hoverEffect` | none | needs D |

## Needs a physical iPad (not covered by simulator tests)

- Playing for 30+ minutes with the screen locked, and the app staying alive in the background.
- Lock-screen and Control Center controls, AirPlay, Bluetooth headphone buttons, and pausing when wired or Bluetooth headphones disconnect.
- Real interruptions: phone and FaceTime calls, Siri, alarms, and another app starting audio.
- Gapless or near-gapless transitions. Not implemented: AVPlayer replaces items, so a short gap is expected.
- FLAC and hi-res playback quality, and the output sample rate (iPadOS may resample).
- Files picker access to iCloud Drive, external drives and third-party providers.
- Stage Manager, an external display, keyboard and trackpad, and VoiceOver end to end.
- Live services: LRCLIB availability and lyric accuracy, Last.fm login and scrobble delivery, your Subsonic server, and real podcast feeds.

## Known limitations

- **Formats:** Ogg Vorbis, Opus, WebM, WMA and APE aren't supported by Apple's frameworks and are rejected at import.
- **Remote servers:** Subsonic servers outside your local network must use HTTPS (App Transport Security).
- **Recommendations:** these are suggestions only. They can be played only if the track is in your library. Otherwise they open on Last.fm.
- **Queue persistence:** the queue is saved on changes and on pause. If the app is force-quit mid-track, the restored position may be a few seconds behind.
- **Excluded by design:** YouTube or YouTube Music streaming, Tidal lossless add-ons, DRM, and Spotify, Apple Music or Musixmatch private APIs.
