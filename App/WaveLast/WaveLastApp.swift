// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import SwiftUI
import WaveLastCore

@main
struct WaveLastApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Brand.accent)
        }
        .commands { PlaybackCommands(model: model) }
    }
}

/// Hardware-keyboard shortcuts (shown when the user holds ⌘ on iPad).
struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(model.player.currentTrack == nil)
            Button("Next Track") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous Track") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Divider()
            Button("Skip Forward 15 Seconds") { model.player.seek(to: model.player.elapsed + 15) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Skip Back 15 Seconds") { model.player.seek(to: model.player.elapsed - 15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
    }
}

enum Brand {
    static let accent = Color(red: 0.13, green: 0.62, blue: 0.70)
    static let deep = Color(red: 0.08, green: 0.12, blue: 0.27)
    static let gradient = LinearGradient(colors: [deep, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
}
