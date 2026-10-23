// swift-tools-version: 5.10
// WaveLast — a native iPad music player.
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "WaveLastKit",
    platforms: [
        .iOS(.v17),
        // macOS is a test host only: it lets the pure logic run with `swift test`
        // on any Mac with a Swift toolchain. The shipping product is iPadOS.
        .macOS(.v14),
    ],
    products: [
        .library(name: "WaveLastCore", targets: ["WaveLastCore"]),
        .library(name: "WaveLastPlayback", targets: ["WaveLastPlayback"]),
    ],
    targets: [
        // Pure logic: models, queue, parsers, network clients, persistence.
        // Depends only on Apple system frameworks (Foundation, CryptoKit, SQLite3).
        .target(name: "WaveLastCore"),
        // Audio: AVFoundation engine, audio session, Now Playing, local import.
        .target(name: "WaveLastPlayback", dependencies: ["WaveLastCore"]),
        .testTarget(
            name: "WaveLastCoreTests",
            dependencies: ["WaveLastCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WaveLastPlaybackTests",
            dependencies: ["WaveLastPlayback", "WaveLastCore"]
        ),
        // Imports the modules WITHOUT @testable, so anything the app needs
        // that is accidentally internal fails here instead of in the app build.
        .testTarget(
            name: "WaveLastPublicAPITests",
            dependencies: ["WaveLastPlayback", "WaveLastCore"]
        ),
    ]
)
