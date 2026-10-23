import Foundation

/// Turns address-bar input into a URL: explicit URLs, bare hosts, or a search query.
public struct URLResolver: Sendable {
    public var searchTemplate: String

    public init(searchTemplate: String = "https://www.google.com/search?q=%s") {
        self.searchTemplate = searchTemplate
    }

    private static let allowedSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]

    public func resolve(_ rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(), Self.allowedSchemes.contains(scheme),
           scheme == "about" || scheme == "data" || url.host != nil || scheme == "file" {
            return url
        }
        if !input.contains(" "), looksLikeHost(input), let url = URL(string: "https://\(input)"), url.host != nil {
            if isLocal(url.host!) { return URL(string: "http://\(input)") }
            return url
        }
        return searchURL(for: input)
    }

    public func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: encoded))
    }

    private func looksLikeHost(_ input: String) -> Bool {
        let hostPart = input.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? input
        let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        if hostOnly.lowercased() == "localhost" { return true }
        if hostOnly.split(separator: ".").count == 4, hostOnly.split(separator: ".").allSatisfy({ UInt8($0) != nil }) { return true }
        guard hostOnly.contains("."), !hostOnly.hasPrefix("."), !hostOnly.hasSuffix(".") else { return false }
        let tld = hostOnly.split(separator: ".").last ?? ""
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    private func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasSuffix(".local")
    }
}
