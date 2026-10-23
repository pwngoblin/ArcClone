import Foundation

/// Converts Adblock Plus–syntax filter lists (EasyList, EasyPrivacy) into WebKit content-blocker
/// rules. Handles the forms that make up most of those lists and skips the rest, rather than
/// approximating them badly:
///   `||domain.com^path$options`  block            `@@||domain.com^$options`  exception
///   `##selector`                  hide everywhere  `site.com##selector`       hide on a site
/// WebKit's url-filter regex has no `|` alternation, so the ABP separator `^` becomes a
/// separator character class (its "end of URL" meaning is dropped).
enum FilterListConverter {
    static let maxRules = 60_000
    private static let separator = "[/:?=&]"
    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "media": "media",
        "xmlhttprequest": "fetch", "subdocument": "document", "websocket": "websocket", "ping": "ping", "other": "raw",
    ]

    static func convert(_ text: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var genericSelectors: [String] = []
        var siteSelectors: [String: [String]] = [:]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if let range = line.range(of: "##") {
                let domains = String(line[..<range.lowerBound])
                let selector = String(line[range.upperBound...])
                guard isSupportedSelector(selector), !domains.contains("~") else { continue }
                if domains.isEmpty { genericSelectors.append(selector) }
                else { for d in domains.split(separator: ",") { siteSelectors[String(d), default: []].append(selector) } }
                continue
            }
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#") { continue }
            let isException = line.hasPrefix("@@")
            guard let rule = networkRule(isException ? String(line.dropFirst(2)) : line, exception: isException) else { continue }
            if isException { exceptions.append(rule) } else { blocks.append(rule) }
        }

        var rules = blocks
        // css-display-none takes a selector list; batch to keep the rule count low.
        for chunk in stride(from: 0, to: genericSelectors.count, by: 60) {
            let selectors = genericSelectors[chunk..<min(chunk + 60, genericSelectors.count)].joined(separator: ", ")
            rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selectors]])
        }
        for (domain, selectors) in siteSelectors.sorted(by: { $0.key < $1.key }) {
            rules.append(["trigger": ["url-filter": ".*", "if-domain": ["*\(domain)"]],
                          "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        }
        // ignore-previous-rules only overrides rules above it, so exceptions go last.
        rules = Array(rules.prefix(maxRules - min(exceptions.count, maxRules / 4)))
        rules += exceptions.prefix(maxRules / 4)
        return rules
    }

    /// `||example.com^/path$third-party,script,domain=a.com|~b.com`
    static func networkRule(_ filter: String, exception: Bool) -> [String: Any]? {
        guard filter.hasPrefix("||") else { return nil } // address-anchored rules only
        var pattern = String(filter.dropFirst(2))
        var options: [String] = []
        if let dollar = pattern.lastIndex(of: "$") {
            options = pattern[pattern.index(after: dollar)...].split(separator: ",").map(String.init)
            pattern = String(pattern[..<dollar])
        }
        guard !pattern.isEmpty, pattern.allSatisfy({ $0.isASCII }), !pattern.contains("|") else { return nil }

        var trigger: [String: Any] = ["url-filter": "^[^:]+://+([^:/]+\\.)?" + regex(for: pattern)]
        var types: [String] = []
        for option in options {
            switch option {
            case "third-party": trigger["load-type"] = ["third-party"]
            case "~third-party", "first-party", "1p": trigger["load-type"] = ["first-party"]
            case "match-case": trigger["url-filter-is-case-sensitive"] = true
            case _ where option.hasPrefix("domain="):
                let domains = option.dropFirst("domain=".count).split(separator: "|").map(String.init)
                let include = domains.filter { !$0.hasPrefix("~") }.map { "*\($0)" }
                let exclude = domains.filter { $0.hasPrefix("~") }.map { "*\($0.dropFirst())" }
                if !include.isEmpty { trigger["if-domain"] = include } else if !exclude.isEmpty { trigger["unless-domain"] = exclude }
            default:
                if let type = resourceTypes[option] { types.append(type) } else { return nil } // unsupported option
            }
        }
        if !types.isEmpty { trigger["resource-type"] = types }
        return ["trigger": trigger, "action": ["type": exception ? "ignore-previous-rules" : "block"]]
    }

    /// ABP wildcard pattern → WebKit's regex subset.
    static func regex(for pattern: String) -> String {
        var out = ""
        for char in pattern {
            switch char {
            case "*": out += ".*"
            case "^": out += separator
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$": out += "\\\(char)"
            default: out.append(char)
            }
        }
        return out
    }

    private static func isSupportedSelector(_ selector: String) -> Bool {
        !selector.isEmpty && !selector.contains(":-abp-") && !selector.contains(":has-text") && !selector.hasPrefix("+js")
            && !selector.contains(":style(") && selector.count < 500
    }
}

/// The built-in list, used even offline: major ad and tracking networks, YouTube's ad endpoints,
/// and common ad containers.
enum BuiltinBlocklist {
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "googletagservices.com",
        "google-analytics.com", "googletagmanager.com", "pagead2.googlesyndication.com", "imasdk.googleapis.com",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com", "indexww.com", "smartadserver.com",
        "yieldmo.com", "sharethrough.com", "triplelift.com", "teads.tv", "media.net", "33across.com", "moatads.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "chartbeat.com", "chartbeat.net", "hotjar.com",
        "mouseflow.com", "fullstory.com", "crazyegg.com", "mixpanel.com", "segment.io", "segment.com", "amplitude.com",
        "branch.io", "app-measurement.com", "adcolony.com", "applovin.com", "unityads.unity3d.com", "inmobi.com",
        "zedo.com", "revcontent.com", "mgid.com", "propellerads.com", "popads.net", "popcash.net", "adsterra.com",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "bidswitch.net", "contextweb.com", "lijit.com",
        "sovrn.com", "gumgum.com", "spotxchange.com", "springserve.com", "adform.net", "adition.com", "serving-sys.com",
        "flashtalking.com", "sizmek.com", "advertising.com", "adtechus.com", "yieldlab.net", "stickyadstv.com",
        "connect.facebook.net", "ads-twitter.com", "static.ads-twitter.com", "ads.linkedin.com", "px.ads.linkedin.com",
        "analytics.tiktok.com", "ads.tiktok.com", "bat.bing.com", "clarity.ms", "ads.yahoo.com", "analytics.yahoo.com",
        "adroll.com", "perfectaudience.com", "demdex.net", "omtrdc.net", "2o7.net", "everesttech.net", "krxd.net",
        "bluekai.com", "exelator.com", "eyeota.net", "tapad.com", "rlcdn.com", "agkn.com", "adsymptotic.com",
        "nativo.com", "zemanta.com", "adblade.com", "infolinks.com", "buysellads.com", "carbonads.net", "ad.doubleclick.net",
    ]

    static let paths = [
        "youtube.com/api/stats/ads", "youtube.com/pagead/", "youtube.com/ptracking", "youtube.com/get_midroll_",
        "/pagead/adview", "/pagead/conversion", "/ads/ga-audiences",
    ]

    static let selectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='google_ads_iframe']", "[id^='div-gpt-ad']", "iframe[src*='doubleclick.net']",
        "iframe[src*='googlesyndication.com']", ".ad-banner", ".ad-container", ".ad-slot", ".advertisement", "[data-ad-slot]",
        "[aria-label='Advertisement']", ".taboola-feed", "[id^='taboola-']", ".OUTBRAIN", "[data-widget-id^='outbrain']",
    ]

    static var rules: [[String: Any]] {
        var rules: [[String: Any]] = domains.map {
            ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?" + FilterListConverter.regex(for: $0) + "[/:]"], "action": ["type": "block"]]
        }
        rules += paths.map { ["trigger": ["url-filter": FilterListConverter.regex(for: $0)], "action": ["type": "block"]] }
        rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        return rules
    }
}
