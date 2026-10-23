// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation
import Security

/// Storage for credentials (Last.fm key/secret/session, Subsonic password).
/// Production uses the Keychain; tests and UI tests use memory.
protocol SecretStore: AnyObject {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

final class KeychainStore: SecretStore {
    private let service: String

    init(service: String = "io.github.sabarishpv.wavelast") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func string(for key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        // Available after first unlock so background scrobbling works with the screen locked.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func string(for key: String) -> String? { values[key] }
    func set(_ value: String?, for key: String) { values[key] = value }
}

enum SecretKey {
    static let lastFMAPIKey = "lastfm.apiKey"
    static let lastFMSecret = "lastfm.sharedSecret"
    static let lastFMSessionKey = "lastfm.sessionKey"
    static let lastFMUsername = "lastfm.username"
    static let subsonicURL = "subsonic.url"
    static let subsonicUser = "subsonic.username"
    static let subsonicPassword = "subsonic.password"
}
