// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 WaveLast contributors

import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

public struct PodcastFeed: Equatable, Sendable {
    public var feedURL: URL
    public var title: String
    public var author: String
    public var summary: String
    public var artworkURL: URL?
    public var episodes: [PodcastEpisode]
}

public struct PodcastEpisode: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { guid }
    public var guid: String
    public var title: String
    public var summary: String
    public var enclosureURL: URL
    public var mimeType: String
    public var byteLength: Int64?
    public var publishedAt: Date?
    public var duration: TimeInterval?
    public var artworkURL: URL?

    /// Converts the episode to a queueable track.
    public func track(in feed: PodcastFeed) -> Track {
        Track(
            id: "podcast:\(feed.feedURL.absoluteString)#\(guid)",
            title: title,
            artist: feed.author.isEmpty ? feed.title : feed.author,
            album: feed.title,
            duration: duration,
            source: .podcast,
            location: .podcastEpisode(feedURL: feed.feedURL, episodeGUID: guid, enclosureURL: enclosureURL),
            artworkRef: (artworkURL ?? feed.artworkURL)?.absoluteString
        )
    }
}

public enum PodcastParseError: Error, Equatable {
    case notRSS
    case malformed(String)
}

/// RSS 2.0 + iTunes namespace parser. Episodes without an audio enclosure are
/// skipped (they cannot be played). Uses Foundation's XMLParser (SAX), so very
/// large feeds stream without building a DOM.
public final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private let feedURL: URL
    private var title = "", author = "", summary = ""
    private var artwork: URL?
    private var episodes: [PodcastEpisode] = []
    private var sawChannel = false

    private var inItem = false
    private var text = ""
    private var item: [String: String] = [:]
    private var enclosure: (url: URL, type: String, length: Int64?)?
    private var itemArtwork: URL?
    private var inChannelImage = false

    private init(feedURL: URL) { self.feedURL = feedURL }

    public static func parse(_ data: Data, feedURL: URL) throws -> PodcastFeed {
        let p = PodcastFeedParser(feedURL: feedURL)
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldProcessNamespaces = false
        guard xml.parse() else {
            throw PodcastParseError.malformed(xml.parserError?.localizedDescription ?? "XML error")
        }
        guard p.sawChannel else { throw PodcastParseError.notRSS }
        return PodcastFeed(
            feedURL: feedURL, title: p.title.trimmed, author: p.author.trimmed,
            summary: p.summary.trimmed, artworkURL: p.artwork, episodes: p.episodes)
    }

    public func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        switch name {
        case "channel": sawChannel = true
        case "item":
            inItem = true
            item = [:]
            enclosure = nil
            itemArtwork = nil
        case "enclosure" where inItem:
            if let u = attributes["url"].flatMap(Self.url) {
                enclosure = (u, attributes["type"] ?? "", attributes["length"].flatMap { Int64($0) })
            }
        case "itunes:image":
            if let u = attributes["href"].flatMap(Self.url) {
                if inItem { itemArtwork = u } else if artwork == nil || !inChannelImage { artwork = u }
            }
        case "image" where !inItem:
            inChannelImage = true
        default: break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if inItem {
            switch name {
            case "item":
                inItem = false
                finishItem()
            case "title", "guid", "pubDate", "itunes:duration", "description", "itunes:summary":
                if item[name] == nil { item[name] = text }
            default: break
            }
        } else {
            switch name {
            case "title" where !inChannelImage && title.isEmpty: title = text
            case "itunes:author" where author.isEmpty: author = text
            case "description" where summary.isEmpty: summary = text
            case "itunes:summary" where summary.isEmpty: summary = text
            case "url" where inChannelImage && artwork == nil: artwork = Self.url(text.trimmed)
            case "image": inChannelImage = false
            default: break
            }
        }
        text = ""
    }

    private func finishItem() {
        guard let enc = enclosure else { return }
        // Trust the declared MIME type; fall back to the file extension only
        // when the type is missing or generic.
        let type = enc.type.lowercased()
        let generic = type.isEmpty || type == "application/octet-stream" || type == "binary/octet-stream"
        let isAudio =
            type.hasPrefix("audio/")
            || (generic && ["mp3", "m4a", "m4b", "aac"].contains(enc.url.pathExtension.lowercased()))
        guard isAudio else { return }
        let guid = (item["guid"]?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? enc.url.absoluteString
        episodes.append(
            PodcastEpisode(
                guid: guid,
                title: item["title"]?.trimmed ?? "Untitled episode",
                summary: (item["itunes:summary"] ?? item["description"] ?? "").trimmed,
                enclosureURL: enc.url,
                mimeType: enc.type,
                byteLength: enc.length,
                publishedAt: item["pubDate"].flatMap { Self.parseRFC822($0.trimmed) },
                duration: item["itunes:duration"].flatMap { Self.parseDuration($0.trimmed) },
                artworkURL: itemArtwork))
    }

    static func url(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmed), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return u
    }

    /// `3600`, `61:05`, `1:01:05` (and fractional seconds) → seconds.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z",
    ]

    public static func parseRFC822(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in rfc822Formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// Fetches and parses feeds through the shared HTTP client.
public struct PodcastFeedLoader: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    public func load(_ url: URL) async throws -> PodcastFeed {
        let data = try await http.data(for: URLRequest(url: url))
        do {
            return try PodcastFeedParser.parse(data, feedURL: url)
        } catch {
            throw NetworkError.invalidResponse("Not a valid podcast feed: \(error)")
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
