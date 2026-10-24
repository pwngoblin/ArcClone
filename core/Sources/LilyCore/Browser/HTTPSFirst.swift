import Foundation

/// HTTPS-First: top-level `http://` navigations to public hosts are tried over HTTPS first (as in
/// Safari and Chrome). A host that can't do HTTPS is loaded over HTTP only after the user agrees,
/// and only for the rest of this session.
@MainActor
enum HTTPSFirst {
    /// Hosts the user allowed over HTTP, or whose HTTPS endpoint redirects back to HTTP.
    static var allowedHTTPHosts: Set<String> = []

    static func upgrade(_ url: URL) -> URL? {
        Preferences.httpsFirstEnabled ? upgrade(url, allowed: allowedHTTPHosts) : nil
    }

    nonisolated static func upgrade(_ url: URL, allowed: Set<String>) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), !isPrivate(host), !allowed.contains(host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    /// Hosts that commonly have no certificate: loopback, LAN names, IP literals, single-label names.
    nonisolated static func isPrivate(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLoopback(host) || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") { return true }
        if host.contains(":") { return true } // IPv6 literal
        if !host.contains(".") { return true }
        return host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { UInt8($0) != nil }
    }

    nonisolated static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
