import Foundation

/// Link tracking protection: query parameters that do nothing but tell a site (and its ad and
/// analytics partners) which click, campaign or email brought you there are removed from links
/// you click, open, type or copy (Settings → Privacy, on by default). Only these parameters go;
/// the rest of the address is kept exactly as it was, and a page's own redirects and form
/// submissions are left alone.
enum LinkTracking {
    /// Click and campaign identifiers that only track; anything starting `utm_` too.
    static let parameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid", "_hsenc", "_hsmi",
        "mkt_tok", "ref_src", "twclid", "ttclid", "li_fat_id", "_ga", "_gl", "oly_anon_id", "oly_enc_id", "vero_id",
    ]

    static func isTracking(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_") || parameters.contains(name)
    }

    @MainActor static var isEnabled: Bool { Preferences.flag(Preferences.Key.removeLinkTracking, default: true) }

    /// `url` without its tracking parameters, or nil when it has none (or isn't a web address).
    static func stripped(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.percentEncodedQueryItems, items.contains(where: { isTracking($0.name.removingPercentEncoding ?? $0.name) }) else { return nil }
        let kept = items.filter { !isTracking($0.name.removingPercentEncoding ?? $0.name) }
        parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    /// The address to use for `url`: stripped when protection is on.
    @MainActor static func cleaned(_ url: URL) -> URL {
        guard isEnabled else { return url }
        return stripped(url) ?? url
    }
}
