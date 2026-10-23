// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Network
import Observation
import WaveLastCore
import WaveLastPlayback

/// Composition root and app-wide state. Created once per launch.
@MainActor
@Observable
final class AppModel {
    // MARK: Long-lived services
    let store: LibraryStore
    let player: PlaybackController
    let importer: LocalImporter
    let lyrics: LyricsService
    let podcastLoader = PodcastFeedLoader()
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored private let nowPlaying = NowPlayingController()
    #if os(iOS)
        @ObservationIgnored private let audioSession = AudioSessionController()
    #endif
    @ObservationIgnored private var scrobbler: LastFMScrobbler?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    // MARK: Observable state
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var subscriptions: [PodcastSubscription] = []
    var isOnline = true
    var isImporting = false
    var lastImport: ImportResult?
    var banner: String?
    var lastFMUser: String?
    /// Observable mirror of "an API key is stored" (the Keychain itself is not observable).
    var lastFMKeyStored = false
    var subsonicConfigured = false
    var startupProblem: String?

    let isUITesting: Bool

    init(isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("-UITestMode")) {
        self.isUITesting = isUITesting
        let fm = FileManager.default
        let support =
            (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let root =
            isUITesting
            ? fm.temporaryDirectory.appendingPathComponent("WaveLastUITest-\(UUID().uuidString)", isDirectory: true)
            : support.appendingPathComponent("WaveLast", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var problem: String?
        let store: LibraryStore
        do {
            store = try LibraryStore(database: SQLiteDatabase(path: root.appendingPathComponent("library.sqlite").path))
        } catch {
            // Keep the app usable (empty, in-memory) and tell the user why.
            problem = "Your library couldn't be opened (\(error)). Changes this session won't be saved."
            store = try! LibraryStore.inMemory()
        }
        self.store = store
        self.startupProblem = problem
        self.secrets = isUITesting ? MemorySecretStore() : KeychainStore()
        let importer = LocalImporter(libraryRoot: root)
        self.importer = importer
        // UI tests never touch the network.
        self.lyrics = LyricsService(lyricsFolder: importer.lyricsFolder, lrclib: isUITesting ? nil : LRCLIBClient())

        let registry = SourceRegistry([LocalFileSource(libraryRoot: root), PodcastSource()])
        self.player = PlaybackController(engine: AVPlayerEngine(), sources: registry, store: store)
        configureSubsonicSource()
        configureLastFM()
        bindSystemIntegration()
        if isUITesting { UITestFixtures.seed(into: self) }
        reload()
        player.restore()
    }

    // MARK: Data

    func reload() {
        tracks = (try? store.tracks()) ?? []
        playlists = (try? store.playlists()) ?? []
        subscriptions = (try? store.subscriptions()) ?? []
    }

    func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        let existing = Set(tracks.map(\.id))
        let result = await importer.importFiles(urls, existingIDs: existing)
        try? store.upsert(result.imported)
        lastImport = result
        reload()
    }

    func delete(_ tracks: [Track]) {
        try? store.deleteTracks(ids: tracks.map(\.id))
        for t in tracks {
            if case .localFile(let rel) = t.location {
                try? FileManager.default.removeItem(at: importer.libraryRoot.appendingPathComponent(rel))
            }
        }
        reload()
    }

    func artworkURL(for track: Track) -> URL? {
        guard let ref = track.artworkRef else { return nil }
        if ref.hasPrefix("http") { return URL(string: ref) }
        if ref.hasPrefix("subsonic-cover:") {
            return subsonicClient()?.coverArtURL(id: String(ref.dropFirst("subsonic-cover:".count)))
        }
        return importer.libraryRoot.appendingPathComponent(ref)
    }

    // MARK: Playlists

    func createPlaylist(named name: String, with tracks: [Track] = []) {
        if let p = try? store.createPlaylist(name: name), !tracks.isEmpty {
            try? store.upsert(tracks)
            try? store.appendToPlaylist(id: p.id, trackIDs: tracks.map(\.id))
        }
        reload()
    }

    func add(_ tracks: [Track], to playlist: Playlist) {
        try? store.upsert(tracks)
        try? store.appendToPlaylist(id: playlist.id, trackIDs: tracks.map(\.id))
        reload()
        banner = "Added to \(playlist.name)"
    }

    // MARK: Subsonic

    func subsonicConfiguration() -> SubsonicConfiguration? {
        guard let s = secrets.string(for: SecretKey.subsonicURL), let url = URL(string: s),
            let user = secrets.string(for: SecretKey.subsonicUser),
            let pass = secrets.string(for: SecretKey.subsonicPassword)
        else { return nil }
        return SubsonicConfiguration(serverURL: url, username: user, password: pass)
    }

    func subsonicClient() -> SubsonicClient? { subsonicConfiguration().map { SubsonicClient(config: $0) } }

    func saveSubsonic(_ config: SubsonicConfiguration?) {
        secrets.set(config?.serverURL.absoluteString, for: SecretKey.subsonicURL)
        secrets.set(config?.username, for: SecretKey.subsonicUser)
        secrets.set(config?.password, for: SecretKey.subsonicPassword)
        configureSubsonicSource()
    }

    private func configureSubsonicSource() {
        if let client = subsonicClient() {
            player.sources.register(SubsonicSource(client: client))
            subsonicConfigured = true
        } else {
            player.sources.unregister(.subsonic)
            subsonicConfigured = false
        }
    }

    // MARK: Last.fm

    func lastFMCredentials() -> LastFMCredentials? {
        guard let k = secrets.string(for: SecretKey.lastFMAPIKey), let s = secrets.string(for: SecretKey.lastFMSecret) else { return nil }
        let c = LastFMCredentials(apiKey: k, sharedSecret: s)
        return c.isPlausible ? c : nil
    }

    func lastFMSession() -> LastFMSession? {
        guard let key = secrets.string(for: SecretKey.lastFMSessionKey), let user = secrets.string(for: SecretKey.lastFMUsername) else {
            return nil
        }
        return LastFMSession(username: user, key: key)
    }

    func saveLastFMCredentials(_ c: LastFMCredentials?) {
        secrets.set(c?.apiKey, for: SecretKey.lastFMAPIKey)
        secrets.set(c?.sharedSecret, for: SecretKey.lastFMSecret)
        lastFMKeyStored = lastFMCredentials() != nil
        if c == nil { saveLastFMSession(nil) }
    }

    func saveLastFMSession(_ s: LastFMSession?) {
        secrets.set(s?.key, for: SecretKey.lastFMSessionKey)
        secrets.set(s?.username, for: SecretKey.lastFMUsername)
        lastFMUser = s?.username
        configureLastFM()
    }

    private func configureLastFM() {
        lastFMUser = lastFMSession()?.username
        lastFMKeyStored = lastFMCredentials() != nil
        let scrobbler = LastFMScrobbler(store: store) { [weak self] in
            guard let self, let c = self.lastFMCredentials(), let s = self.lastFMSession() else { return nil }
            return (LastFMClient(credentials: c), s)
        }
        scrobbler.onSessionInvalid = { [weak self] in
            self?.saveLastFMSession(nil)
            self?.banner = "Last.fm signed you out. Reconnect in Settings."
        }
        self.scrobbler = scrobbler
        player.scrobbler = scrobbler
        scrobbler.flush()
    }

    // MARK: System integration

    private func bindSystemIntegration() {
        #if os(iOS)
            do {
                try audioSession.configure()
            } catch {
                startupProblem = "Audio couldn't be configured for background playback: \(error.localizedDescription)"
            }
            audioSession.onEvent = { [weak self] in self?.player.handleAudioSession($0) }
            audioSession.startObserving()
        #endif
        if !BackgroundAudioConfiguration.validate(infoDictionary: Bundle.main.infoDictionary) {
            startupProblem = "Background audio is not enabled in this build."
        }
        nowPlaying.bind { [weak self] in self?.player.handleRemote($0) ?? false }
        player.onNowPlayingChange = { [weak self] in self?.publishNowPlaying() }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = online && !self.isOnline
                self.isOnline = online
                if cameBack { self.scrobbler?.flush() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "wavelast.network"))
    }

    /// Activates the audio session the first time something plays.
    func activateAudioIfNeeded() {
        #if os(iOS)
            try? audioSession.activate()
        #endif
    }

    private func publishNowPlaying() {
        guard let t = player.currentTrack else {
            nowPlaying.update(nil)
            return
        }
        let info = NowPlayingInfoBuilder.info(
            track: t, elapsed: player.elapsed, duration: player.duration, isPlaying: player.isPlaying,
            queueIndex: player.queue.currentIndex, queueCount: player.queue.entries.count)
        let art = artworkURL(for: t)
        nowPlaying.update(info, artworkKey: art?.isFileURL == true ? art?.path : nil) {
            art.flatMap { $0.isFileURL ? try? Data(contentsOf: $0) : nil }
        }
    }

    // MARK: Playback helpers used by views

    func play(_ tracks: [Track], startAt index: Int = 0) {
        activateAudioIfNeeded()
        player.play(tracks, startAt: index)
    }
}
