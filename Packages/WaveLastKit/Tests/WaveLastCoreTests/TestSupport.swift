// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

@testable import WaveLastCore

/// Canned HTTP responses. No test in this package touches the real network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: Data, headers: [String: String] = [:])
        case error(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .error(URLError(.unknown)) : replies.removeFirst()
        }
        switch reply {
        case .error(let e):
            throw e
        case .response(let status, let body, let headers):
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, r)
        }
    }

    var requestCount: Int { lock.withLock { requests.count } }
}

/// Records requested back-off delays instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [TimeInterval] = []
    func record(_ d: TimeInterval) { lock.withLock { delays.append(d) } }
}

func client(_ transport: MockTransport, retries: Int = 3, recorder: SleepRecorder? = nil) -> HTTPClient {
    HTTPClient(
        transport: transport, timeout: 5, retry: RetryPolicy(maxAttempts: retries, baseDelay: 0.5, maxDelay: 8),
        sleep: { d in recorder?.record(d) })
}

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static func string(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }
}

func ok(_ name: String) -> MockTransport.Reply { .response(status: 200, body: Fixture.data(name)) }
func status(_ code: Int, _ body: String = "") -> MockTransport.Reply { .response(status: code, body: Data(body.utf8)) }

func makeTrack(_ n: Int, duration: TimeInterval? = 200) -> Track {
    Track(
        id: "t\(n)", title: "Track \(n)", artist: "Artist", album: "Album", duration: duration,
        source: .local, location: .localFile(relativePath: "Music/t\(n).m4a"))
}

/// Deterministic RNG for shuffle tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func queryItems(_ request: URLRequest) -> [String: String] {
    let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
    return Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

func formItems(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var c = URLComponents()
    c.percentEncodedQuery = body
    return Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}
