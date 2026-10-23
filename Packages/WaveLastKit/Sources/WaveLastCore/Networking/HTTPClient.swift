// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

/// Errors surfaced to the UI. Every network call maps failures to one of these
/// so screens can show a specific message (offline vs server down vs bad data).
public enum NetworkError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case http(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse(String)
    case cancelled
    case other(String)

    /// Whether repeating the same request later might succeed.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .rateLimited: return true
        case .http(let s): return s >= 500
        case .offline, .invalidResponse, .cancelled, .other: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .offline: return "You're offline. Check your connection and try again."
        case .timedOut: return "The server took too long to respond."
        case .http(let s) where s == 401 || s == 403: return "The server rejected the request (\(s)). Check your account settings."
        case .http(let s) where s == 404: return "Not found."
        case .http(let s): return "The server returned an error (\(s))."
        case .rateLimited: return "Too many requests. Please wait a moment."
        case .invalidResponse: return "The server sent a response WaveLast couldn't read."
        case .cancelled: return "Cancelled."
        case .other(let m): return m
        }
    }

    static func from(_ error: Error) -> NetworkError {
        if let e = error as? NetworkError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .other(ns.localizedDescription) }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return .offline
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorCancelled: return .cancelled
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse,
            NSURLErrorCannotDecodeContentData, NSURLErrorCannotDecodeRawData:
            return .invalidResponse(ns.localizedDescription)
        default: return .other(ns.localizedDescription)
        }
    }
}

/// Minimal transport so tests can substitute canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse("Not an HTTP response")
        }
        return (data, http)
    }
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// Exponential backoff; honours a server Retry-After when present.
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(maxDelay, max(0, retryAfter)) }
        return min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
    }
}

/// HTTP client with per-request timeout, status mapping and retry for
/// transient failures. Never retries 4xx (other than 429).
public struct HTTPClient: Sendable {
    public let transport: HTTPTransport
    public var timeout: TimeInterval
    public var retry: RetryPolicy
    public var userAgent: String
    /// Injected so tests do not actually sleep.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        timeout: TimeInterval = 15,
        retry: RetryPolicy = RetryPolicy(),
        userAgent: String = WaveLastInfo.userAgent,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { s in
            try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.timeout = timeout
        self.retry = retry
        self.userAgent = userAgent
        self.sleep = sleep
    }

    /// Performs the request and returns the body for 2xx responses.
    public func data(for request: URLRequest) async throws -> Data {
        let (data, status) = try await response(for: request)
        guard (200..<300).contains(status) else { throw NetworkError.http(status: status) }
        return data
    }

    /// Performs the request, retrying transport failures, 5xx and 429.
    /// Returns the body and status for any other response (including 4xx),
    /// so APIs that put error details in the body can read them.
    public func response(for request: URLRequest) async throws -> (Data, Int) {
        var req = request
        req.timeoutInterval = timeout
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                try Task.checkCancellation()
                let (data, response) = try await transport.send(req)
                switch response.statusCode {
                case 429:
                    let ra = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    throw NetworkError.rateLimited(retryAfter: ra)
                case 500...:
                    throw NetworkError.http(status: response.statusCode)
                default:
                    return (data, response.statusCode)
                }
            } catch {
                let mapped = NetworkError.from(error)
                guard mapped.isTransient, attempt < retry.maxAttempts else { throw mapped }
                var retryAfter: TimeInterval?
                if case .rateLimited(let ra) = mapped { retryAfter = ra }
                try await sleep(retry.delay(forAttempt: attempt, retryAfter: retryAfter))
            }
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from request: URLRequest, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await data(for: request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.invalidResponse("Could not decode \(T.self): \(error)")
        }
    }
}

public enum WaveLastInfo {
    public static let version = "0.1.0"
    public static let sourceURL = URL(string: "https://github.com/SabarishPv/wavelast_ipad")!
    /// Identifies the app to open APIs (LRCLIB asks clients to do this).
    public static let userAgent = "WaveLast/\(version) (+https://github.com/SabarishPv/wavelast_ipad)"
}
