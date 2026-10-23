// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import WaveLastCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LastFMSettings()
            SubsonicSettings()
            Section("Storage") {
                LabeledContent("Songs in library", value: "\(model.tracks.filter { $0.source == .local }.count)")
                LabeledContent("Playlists", value: "\(model.playlists.count)")
            }
            Section("About") {
                NavigationLink("Licenses & Credits") { AboutView() }
                    .accessibilityIdentifier("settings.about")
                LabeledContent("Version", value: WaveLastInfo.version)
            }
        }
        .navigationTitle("Settings")
    }
}

/// Last.fm connection using the official desktop-style auth flow. Each user
/// supplies their own (free) API account; WaveLast ships no keys.
struct LastFMSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var pendingToken: String?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            if let user = model.lastFMUser {
                LabeledContent("Connected as", value: user)
                Button("Disconnect", role: .destructive) { model.saveLastFMSession(nil) }
            } else if model.lastFMKeyStored, let creds = model.lastFMCredentials() {
                if let token = pendingToken {
                    Text("Approve WaveLast on the Last.fm page that opened, then come back and tap Finish.")
                        .font(.callout)
                    Button("Finish Connecting") { Task { await finish(creds, token: token) } }.disabled(working)
                    Button("Open Last.fm Again") { openURL(LastFMClient(credentials: creds).authorizationURL(token: token)) }
                } else {
                    Button("Connect Last.fm Account") { Task { await start(creds) } }.disabled(working || !model.isOnline)
                }
                Button("Remove API Key", role: .destructive) {
                    model.saveLastFMCredentials(nil); pendingToken = nil
                }
            } else {
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Shared secret", text: $secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") {
                    let c = LastFMCredentials(apiKey: apiKey, sharedSecret: secret)
                    if c.isPlausible {
                        model.saveLastFMCredentials(c)
                        apiKey = ""; secret = ""; message = nil
                    } else {
                        message = "Both values should be 32 letters/numbers from your Last.fm API account page."
                    }
                }
                .disabled(apiKey.isEmpty || secret.isEmpty)
                Link("Create a free Last.fm API account", destination: URL(string: "https://www.last.fm/api/account/create")!)
            }
            if working { ProgressView() }
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: {
            Text("Last.fm")
        } footer: {
            Text(
                "Scrobbles songs you play (not podcasts) and powers Discover. Keys and your session are stored in the iPad Keychain. WaveLast never asks for your Last.fm password."
            )
        }
    }

    private func start(_ c: LastFMCredentials) async {
        working = true
        defer { working = false }
        do {
            let client = LastFMClient(credentials: c)
            let token = try await client.getToken()
            pendingToken = token
            openURL(client.authorizationURL(token: token))
        } catch {
            message = describe(error)
        }
    }

    private func finish(_ c: LastFMCredentials, token: String) async {
        working = true
        defer { working = false }
        do {
            let session = try await LastFMClient(credentials: c).getSession(token: token)
            model.saveLastFMSession(session)
            pendingToken = nil
            message = nil
        } catch let e as LastFMAPIError where e.isUnauthorizedToken {
            message = "Last.fm hasn't been approved yet. Approve access in the browser, then tap Finish again."
        } catch {
            message = describe(error)
            if (error as? LastFMAPIError)?.code == 15 { pendingToken = nil }
        }
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? LastFMAPIError { return e.message }
        if let e = error as? NetworkError { return e.userMessage }
        return error.localizedDescription
    }
}

struct SubsonicSettings: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var testing = false
    @State private var message: String?

    var body: some View {
        Section {
            if model.subsonicConfigured, let config = model.subsonicConfiguration() {
                LabeledContent("Server", value: config.serverURL.host() ?? config.serverURL.absoluteString)
                LabeledContent("User", value: config.username)
                Button("Remove Server", role: .destructive) { model.saveSubsonic(nil) }
            } else {
                TextField("https://music.example.com", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Username", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button("Test & Save") { Task { await testAndSave() } }
                    .disabled(url.isEmpty || user.isEmpty || password.isEmpty || testing)
            }
            if testing { ProgressView() }
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: {
            Text("Music Server (Subsonic API)")
        } footer: {
            Text(
                "For servers you run or have an account on. Uses token authentication, so your password isn't sent in plain text. Remote servers must use HTTPS; plain HTTP works only on your local network."
            )
        }
    }

    private func testAndSave() async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            message = "Enter the full server address, starting with https://"
            return
        }
        testing = true
        defer { testing = false }
        let config = SubsonicConfiguration(serverURL: u, username: user, password: password)
        do {
            try await SubsonicClient(config: config).ping()
            model.saveSubsonic(config)
            url = ""; user = ""; password = ""; message = nil
        } catch let e as SubsonicAPIError {
            message = e.isAuthenticationError ? "Wrong username or password (or the server doesn't support token login)." : e.message
        } catch let e as NetworkError {
            message = e.userMessage
        } catch {
            message = error.localizedDescription
        }
    }
}

/// "Appropriate Legal Notices" required by GPL-3.0 §0 and §5(d).
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WaveLast").font(.title2.bold())
                    Text("Copyright © 2026 WaveLast contributors.")
                    Text(
                        "WaveLast is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It comes with ABSOLUTELY NO WARRANTY."
                    )
                    .font(.callout)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("about.license")
                Link("Source code", destination: WaveLastInfo.sourceURL)
                Link("GNU GPL v3 full text", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
            Section("Credits") {
                Text(
                    "Parts of WaveLast's logic (Last.fm request signing, text matching, playback-resolve design) are adapted from LastWave-Native by the LastWave authors / Clash-Projects contributors, licensed under GPL-3.0."
                )
                Link("LastWave-Native source", destination: URL(string: "https://github.com/Clash-Projects/LastWave-Native")!)
                Text(
                    "WaveLast is an independent project and is not affiliated with or endorsed by LastWave, Clash-Projects, Last.fm, LRCLIB or Subsonic."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Services") {
                Text("Lyrics: LRCLIB (lrclib.net), a free and open lyrics database.")
                Text("Scrobbling and recommendations: the official Last.fm API, using your own API account.")
            }
        }
        .navigationTitle("Licenses & Credits")
    }
}
