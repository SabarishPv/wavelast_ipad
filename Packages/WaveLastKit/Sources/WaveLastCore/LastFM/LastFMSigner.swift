// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors
//
// Derived from LastWave-Native `data/network/LastFmSigner.kt`
// (https://github.com/Clash-Projects/LastWave-Native, GPL-3.0,
// Copyright (C) LastWave authors / Clash-Projects contributors).
// Implements Last.fm's published signing scheme: https://www.last.fm/api/authspec

import CryptoKit
import Foundation

public enum LastFMSigner {
    private static let skipped: Set<String> = ["format", "callback", "api_sig"]

    /// Strips everything except hex digits and lowercases. Last.fm keys and
    /// secrets are 32 lowercase hex characters, so stray whitespace or
    /// invisible characters pasted from a browser are removed.
    public static func normalizeKey(_ raw: String) -> String {
        String(
            raw.lowercased().unicodeScalars.filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
                .map(Character.init))
    }

    /// 1. drop `format`, `callback`, `api_sig`; 2. sort keys (byte order);
    /// 3. concatenate key+value; 4. append secret; 5. MD5 → lowercase hex.
    public static func sign(_ params: [String: String], secret: String) -> String {
        let base =
            params
            .filter { !skipped.contains($0.key) }
            .sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
            .map { $0.key + $0.value }
            .joined() + secret
        return md5Hex(base)
    }

    public static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
