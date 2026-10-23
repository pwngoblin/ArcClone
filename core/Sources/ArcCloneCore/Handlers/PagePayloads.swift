import Foundation

/// Schemas for page → native events. They arrive through our own injections, but those read
/// attacker-controlled DOM, so every field is treated as untrusted: decoded into a fixed shape,
/// length-bounded, and URLs must belong to the frame's security origin (set by WebKit, not the page).
enum PagePayload {
    static let maxTitle = 1_000
    static let maxURL = 4_096
    static let maxSelection = 20_000
    static let maxMessage = 500

    struct DidChange: Decodable {
        var url: String
        var title: String?
        var description: String?
        var favicon: String?
        var themeColor: String?
    }

    struct Selection: Decodable {
        var url: String
        var text: String
        var truncated: Bool?
    }

    struct VideoChanged: Decodable {
        var videoId: String?
        var url: String
    }

    struct RuntimeError: Decodable {
        var message: String?
        var source: String?
        var line: Int?
        var column: Int?
    }

    /// Validated page metadata, safe to show and to store.
    struct Metadata: Equatable {
        var url: URL
        var title: String?
        var favicon: URL?
        var themeColor: String?
        var description: String?

        var json: JSONValue {
            ["url": .string(url.absoluteString), "title": JSONValue(title), "favicon": JSONValue(favicon?.absoluteString),
             "themeColor": JSONValue(themeColor), "description": JSONValue(description)]
        }
    }

    static func metadata(_ p: DidChange, origin: URL?) throws -> Metadata {
        let url = try sameOrigin(p.url, origin: origin)
        let favicon = p.favicon.flatMap { raw -> URL? in
            guard raw.count <= maxURL, let u = URL(string: raw), u.scheme == "https" || u.scheme == "http" else { return nil }
            return u
        }
        let color = p.themeColor.flatMap { raw -> String? in
            raw.count <= 64 && raw.range(of: #"^[#a-zA-Z0-9(),.%\s-]+$"#, options: .regularExpression) != nil ? raw : nil
        }
        return Metadata(url: url, title: bounded(p.title, maxTitle), favicon: favicon, themeColor: color,
                        description: bounded(p.description, maxTitle))
    }

    static func selection(_ p: Selection, origin: URL?) throws -> (url: URL, text: String) {
        (try sameOrigin(p.url, origin: origin), String(p.text.prefix(maxSelection)))
    }

    /// YouTube ids are 11 URL-safe characters; accepted only from YouTube's own origin.
    static func videoID(_ p: VideoChanged, origin: URL?) throws -> String? {
        let url = try sameOrigin(p.url, origin: origin)
        guard let host = url.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            throw IPCError.invalidParams("Video events are only accepted from YouTube")
        }
        guard let id = p.videoId else { return nil }
        guard id.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil else { throw IPCError.invalidParams("Bad video id") }
        return id
    }

    /// The URL a page reports must match the frame's real origin (scheme, host, port).
    static func sameOrigin(_ raw: String, origin: URL?) throws -> URL {
        guard raw.count <= maxURL, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            throw IPCError.invalidParams("Invalid page URL")
        }
        guard let origin else { return url }
        let port = { (u: URL) in u.port ?? (u.scheme == "https" ? 443 : u.scheme == "http" ? 80 : 0) }
        guard scheme == origin.scheme?.lowercased(), url.host?.lowercased() == origin.host?.lowercased(), port(url) == port(origin) else {
            throw IPCError("origin_mismatch", "Page URL does not match the frame's origin")
        }
        return url
    }

    static func bounded(_ value: String?, _ max: Int) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(max))
    }
}

extension IPCRouter {
    /// Registers a route whose payload must decode into `T`; anything else is rejected with `invalid_params`.
    public func on<T: Decodable>(_ type: String, from allowed: Set<IPCSource.Kind>, as payload: T.Type,
                                 _ handler: @escaping @MainActor (IPCContext, T) async throws -> JSONValue) {
        on(type, from: allowed) { context, raw in
            let value: T
            do {
                value = try raw.decode(T.self)
            } catch {
                throw IPCError.invalidParams("Invalid \(type) payload")
            }
            return try await handler(context, value)
        }
    }
}

extension IPCSource {
    /// Builds the origin URL WebKit reports for a frame (`WKSecurityOrigin`), never the page's own claim.
    static func originURL(protocol scheme: String, host: String, port: Int) -> URL? {
        guard !scheme.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        if port > 0 { parts.port = port }
        return parts.url
    }
}
