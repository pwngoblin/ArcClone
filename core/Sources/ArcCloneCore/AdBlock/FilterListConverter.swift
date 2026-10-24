import Foundation

/// Filter lists compiled for WebKit: content-rule lists (JSON) plus the procedural cosmetic
/// filters that run in the page, keyed by domain.
struct CompiledFilters: Sendable {
    var chunks: [String]
    var ruleCount: Int
    var procedural: [String: [ProceduralFilter]]
}

/// Converts Adblock Plus / uBlock Origin / AdGuard filter lists into WebKit content-blocker rules.
///
/// WebKit gives the app no say over individual requests, so (like Brave on iOS) the lists are
/// translated ahead of time into WebKit's own rule format, which it enforces in the network and
/// web content processes. Supported:
///   `||host^path`, `|https://…|`, `/plain/path.`, `/regex/` (WebKit's subset)   network blocks
///   `@@…`  exceptions, including `$document`, `$elemhide`, `$generichide`, `$specifichide`
///   `$third-party` `$1p` `$script` `$xhr` `$frame` `$popup` `$domain=` `$important` `$badfilter` `$match-case` …
///   `##sel`  `site##sel`  `~site##sel`  `site#@#sel`                             element hiding
///   `site##sel:has-text(…)` `:upward(…)` `:min-text-length(…)` `#?#`              procedural (in page)
///   `0.0.0.0 host`                                                               hosts files
/// Skipped rather than approximated: scriptlets (`+js`, they would run list-supplied JavaScript in
/// pages), CSS injection (`:style`, `#$#`), HTML filtering (`##^`), redirects, `$csp`,
/// `$removeparam`, and anything else WebKit can't express exactly.
enum FilterListConverter {
    /// WebKit accepts up to 150,000 rules per list; smaller lists compile faster and in less memory.
    static let chunkSize = 50_000
    static let maxChunks = 8
    static let maxProceduralPerDomain = 64
    private static let separator = "[/:?=&]"
    private static let hostPrefix = "^[^:]+://+([^:/]+\\.)?"
    /// Everything a page loads except the page itself, so a typeless exception unblocks resources
    /// without also switching off element hiding on pages at that address.
    static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "fetch", "websocket"]
    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet", "font": "font",
        "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch", "websocket": "websocket", "ping": "ping",
        "beacon": "ping", "other": "raw", "popup": "popup",
    ]

    /// Rules gathered from a list before they are split into WebKit lists.
    struct Parsed {
        var blocks: [[String: Any]] = []
        var important: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var generic: [(selector: String, except: [String])] = []
        var site: [String: [String]] = [:]
        var procedural: [(domains: [String], filter: ProceduralFilter, raw: String)] = []
        /// Selector → domains where `#@#` turns it off ("" means everywhere).
        var cosmeticExceptions: [String: Set<String>] = [:]
        var genericHide: Set<String> = []
        var specificHide: Set<String> = []
        var skipped = 0

        /// Element hiding (generic and per-site) batched into `css-display-none` rules.
        func cosmeticRules() -> [[String: Any]] {
            var rules: [[String: Any]] = []
            // Grouped by the sites each selector is off on (besides the `$generichide` ones, which all share).
            var byExceptions: [[String]: [String]] = [:]
            for (selector, except) in generic {
                let exceptions = cosmeticExceptions[selector] ?? []
                guard !exceptions.contains("") else { continue }
                let extra = except.isEmpty && exceptions.isEmpty ? [] : Set(except).union(exceptions).subtracting(genericHide).sorted()
                byExceptions[extra, default: []].append(selector)
            }
            let shared = genericHide.sorted()
            for (extra, selectors) in byExceptions.sorted(by: { $0.key.count < $1.key.count }) {
                let unless = extra.isEmpty ? shared : (extra + shared).sorted()
                // css-display-none takes a selector list; batch to keep the rule count low.
                for start in stride(from: 0, to: selectors.count, by: 60) {
                    var trigger: [String: Any] = ["url-filter": ".*"]
                    if !unless.isEmpty { trigger["unless-domain"] = unless.map { "*\($0)" } }
                    let batch = selectors[start..<min(start + 60, selectors.count)].joined(separator: ", ")
                    rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": batch]])
                }
            }
            for (domain, selectors) in site.sorted(by: { $0.key < $1.key }) where !FilterListConverter.covers(specificHide, domain) {
                let kept = selectors.filter { !FilterListConverter.covers(cosmeticExceptions[$0] ?? [], domain) }
                for start in stride(from: 0, to: kept.count, by: 60) {
                    rules.append(["trigger": ["url-filter": ".*", "if-domain": ["*\(domain)"]],
                                  "action": ["type": "css-display-none", "selector": kept[start..<min(start + 60, kept.count)].joined(separator: ", ")]])
                }
            }
            return rules
        }

        /// Procedural filters by domain, minus `#@#` exceptions and `$elemhide` sites.
        func proceduralByDomain() -> [String: [ProceduralFilter]] {
            var result: [String: [ProceduralFilter]] = [:]
            for (domains, filter, raw) in procedural {
                for domain in domains where !FilterListConverter.covers(specificHide, domain)
                    && !FilterListConverter.covers(cosmeticExceptions[raw] ?? [], domain) {
                    if result[domain, default: []].count < FilterListConverter.maxProceduralPerDomain, !result[domain, default: []].contains(filter) {
                        result[domain, default: []].append(filter)
                    }
                }
            }
            return result
        }
    }

    // MARK: Whole lists

    static func compile(_ text: String, chunkSize: Int = chunkSize) throws -> CompiledFilters {
        let parsed = parse(text)
        let (lists, count) = splitCounting(parsed, chunkSize: chunkSize)
        let chunks = try lists.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return CompiledFilters(chunks: chunks, ruleCount: count, procedural: parsed.proceduralByDomain())
    }

    /// One WebKit list's worth of rules (tests and small lists).
    static func convert(_ text: String) -> [[String: Any]] {
        split(parse(text), chunkSize: 150_000).first ?? []
    }

    /// `ignore-previous-rules` only overrides earlier rules in the same list, so every chunk ends
    /// with all the exceptions, then the `$important` blocks that exceptions mustn't undo.
    static func split(_ parsed: Parsed, chunkSize: Int) -> [[[String: Any]]] {
        splitCounting(parsed, chunkSize: chunkSize).lists
    }

    /// The lists, and how many distinct rules they hold (the tail counted once).
    private static func splitCounting(_ parsed: Parsed, chunkSize: Int) -> (lists: [[[String: Any]]], count: Int) {
        let base = parsed.blocks + parsed.cosmeticRules()
        let tail = Array(parsed.exceptions.prefix(chunkSize / 4)) + Array(parsed.important.prefix(chunkSize / 4))
        if base.isEmpty { return parsed.important.isEmpty ? ([], 0) : ([tail], tail.count) }
        let room = chunkSize - tail.count
        let lists = stride(from: 0, to: base.count, by: room).prefix(maxChunks).map { start in
            Array(base[start..<min(start + room, base.count)]) + tail
        }
        return (lists, lists.reduce(0) { $0 + $1.count - tail.count } + tail.count)
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        let lines = text.split(whereSeparator: \.isNewline)
        // `$badfilter` cancels the identical filter wherever it appears in the lists.
        var cancelled = Set<String>()
        for line in lines where line.contains("badfilter") {
            let filter = line.trimmingCharacters(in: .whitespaces)
            if let key = canonical(filter, dropping: "badfilter"), key != canonical(filter) { cancelled.insert(key) }
        }

        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || (line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#") && !line.hasPrefix("#?#")) { continue }
            if let host = hostsEntry(line) { line = "||\(host)^" }
            if let cosmetic = cosmeticParts(line) {
                addCosmetic(cosmetic, to: &parsed)
                continue
            }
            if !cancelled.isEmpty, let key = canonical(line), cancelled.contains(key) { continue }
            if line.contains("badfilter"), splitOptions(line).1.contains(where: { $0.lowercased() == "badfilter" }) { continue }
            let exception = line.hasPrefix("@@")
            switch network(exception ? String(line.dropFirst(2)) : line, exception: exception) {
            case .rules(let rules, let important):
                if exception { parsed.exceptions += rules } else if important { parsed.important += rules } else { parsed.blocks += rules }
            case .scope(let scopes, let domains):
                if scopes.contains("document") {
                    parsed.exceptions.append(["trigger": ["url-filter": ".*", "if-domain": domains.map { "*\($0)" }], "action": ["type": "ignore-previous-rules"]])
                }
                if scopes.contains("document") || scopes.contains("elemhide") {
                    parsed.genericHide.formUnion(domains)
                    parsed.specificHide.formUnion(domains)
                }
                if scopes.contains("generichide") { parsed.genericHide.formUnion(domains) }
                if scopes.contains("specifichide") { parsed.specificHide.formUnion(domains) }
            case .unsupported:
                parsed.skipped += 1
            }
        }
        return parsed
    }

    // MARK: Element hiding

    struct CosmeticParts {
        var include: [String]
        var exclude: [String]
        var exception: Bool
        var extended: Bool
        var selector: String
    }

    /// Splits `domains##selector`, `domains#@#selector`, `domains#?#selector`; nil for network filters.
    /// Other separators (`#$#` CSS injection, `#%#` scripts, `##+js`) come back as unsupported cosmetics.
    static func cosmeticParts(_ line: String) -> CosmeticParts? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let domains = line[..<hash]
        guard domains.allSatisfy({ $0.isLetter || $0.isNumber || ".,~*-_".contains($0) }) else { return nil }
        let after = line[line.index(after: hash)...]
        let markers: [(String, Bool, Bool)] = [("#", false, false), ("@#", true, false), ("?#", false, true), ("@?#", true, true)]
        for unsupported in ["$#", "@$#", "%#", "@%#", "$?#", "@$?#"] where after.hasPrefix(unsupported) {
            return CosmeticParts(include: [], exclude: [], exception: false, extended: false, selector: "+js()")
        }
        guard let (marker, exception, extended) = markers.first(where: { after.hasPrefix($0.0) }) else { return nil }
        var include: [String] = []
        var exclude: [String] = []
        for entry in domains.split(separator: ",") where entry != "*" {
            let name = entry.lowercased()
            if name.hasPrefix("~") { exclude.append(String(name.dropFirst())) } else { include.append(name) }
        }
        return CosmeticParts(include: include, exclude: exclude, exception: exception, extended: extended,
                             selector: String(after.dropFirst(marker.count)))
    }

    private static func addCosmetic(_ parts: CosmeticParts, to parsed: inout Parsed) {
        guard var (include, exclude) = plainDomains(parts.include, parts.exclude) else { parsed.skipped += 1; return }
        if parts.exception {
            let key = parts.selector.trimmingCharacters(in: .whitespaces)
            if include.isEmpty { parsed.cosmeticExceptions[key, default: []].insert("") }
            for domain in include { parsed.cosmeticExceptions[key, default: []].insert(domain) }
            if let normalized = CosmeticSelector.parse(key), case .css(let selector) = normalized, selector != key {
                parsed.cosmeticExceptions[selector, default: []].formUnion(parsed.cosmeticExceptions[key] ?? [])
            }
            return
        }
        // `site.com,~sub.site.com##x`: WebKit can't combine if-domain and unless-domain, and
        // dropping the exclusion would hide things the list says to leave alone.
        guard let kept = narrowed(include, excluding: exclude) else { parsed.skipped += 1; return }
        include = kept
        exclude = include.isEmpty ? exclude : []
        switch CosmeticSelector.parse(parts.selector) {
        case .css(let selector):
            if include.isEmpty { parsed.generic.append((selector, exclude)) }
            else { for domain in include { parsed.site[domain, default: []].append(selector) } }
        case .procedural(let filter):
            // Generic procedural filters would run on every page; lists use them per site.
            guard !include.isEmpty else { parsed.skipped += 1; return }
            parsed.procedural.append((include, filter, parts.selector.trimmingCharacters(in: .whitespaces)))
        case nil:
            parsed.skipped += 1
        }
    }

    // MARK: Network filters

    enum Network {
        case rules([[String: Any]], important: Bool)
        /// An exception that switches off filtering features on whole sites (`$document`, `$elemhide`, …).
        case scope(Set<String>, domains: [String])
        case unsupported
    }

    /// The rules for one network filter (without its `@@`), or an empty array when unsupported.
    static func networkRules(_ filter: String, exception: Bool) -> [[String: Any]] {
        if case .rules(let rules, _) = network(filter, exception: exception) { return rules }
        return []
    }

    static func network(_ filter: String, exception: Bool) -> Network {
        let (pattern, options) = splitOptions(filter)
        guard pattern.allSatisfy(\.isASCII) else { return .unsupported }

        var trigger: [String: Any] = [:]
        var types: [String] = []
        var negatedTypes: Set<String> = []
        var frames: Bool?
        var important = false
        var scopes = Set<String>()
        var includeDomains: [String] = []
        for option in options {
            let name = option.lowercased()
            switch name {
            case "third-party", "3p": trigger["load-type"] = ["third-party"]
            case "~third-party", "first-party", "1p", "~3p": trigger["load-type"] = ["first-party"]
            case "match-case": trigger["url-filter-is-case-sensitive"] = true
            case "important": important = true
            case "all": break
            case "subdocument", "frame": frames = true
            case "~subdocument", "~frame": negatedTypes.insert("frame")
            case "document", "doc": if exception { scopes.insert("document") } else { types.append("document") }
            case "elemhide", "ehide": scopes.insert("elemhide")
            case "generichide", "ghide": scopes.insert("generichide")
            case "specifichide", "shide": scopes.insert("specifichide")
            case _ where name.hasPrefix("domain=") || name.hasPrefix("from="):
                let list = option[option.index(after: option.firstIndex(of: "=")!)...].lowercased().split(separator: "|").map(String.init)
                guard let (include, exclude) = plainDomains(list.filter { !$0.hasPrefix("~") }, list.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }),
                      let kept = narrowed(include, excluding: exclude) else { return .unsupported }
                includeDomains = kept
                if !kept.isEmpty { trigger["if-domain"] = kept.map { "*\($0)" } } else if !exclude.isEmpty { trigger["unless-domain"] = exclude.map { "*\($0)" } }
            case _ where name.hasPrefix("~"):
                guard let type = resourceTypes[String(name.dropFirst())] else {
                    if name == "~object" { continue }
                    return .unsupported
                }
                negatedTypes.insert(type)
            default:
                guard let type = resourceTypes[name] else { return .unsupported } // redirect, csp, removeparam, …
                types.append(type)
            }
        }

        if exception, !scopes.isEmpty {
            guard let domains = scopeDomains(pattern, fallback: includeDomains), !domains.isEmpty else { return .unsupported }
            return .scope(scopes, domains: domains)
        }
        guard scopes.isEmpty, let urlFilter = urlFilter(for: pattern) else { return .unsupported }
        // A pattern-less filter (`$script,domain=x.com`) needs a site, or it would block everything.
        if urlFilter == ".*", trigger["if-domain"] == nil { return .unsupported }
        trigger["url-filter"] = urlFilter

        let typeless = types.isEmpty && frames == nil && negatedTypes.isEmpty
        if !negatedTypes.isEmpty {
            // `$~script`: every other kind of resource, frames included unless also negated.
            if types.isEmpty && frames == nil && !negatedTypes.contains("frame") { frames = true }
            types = (types.isEmpty ? subresourceTypes : types).filter { !negatedTypes.contains($0) }
        }
        let action: [String: Any] = ["type": exception ? "ignore-previous-rules" : "block"]
        var rules: [[String: Any]] = []
        if typeless && !exception {
            rules.append(["trigger": trigger, "action": action])
        } else if !types.isEmpty || typeless {
            var main = trigger
            main["resource-type"] = typeless ? subresourceTypes : types
            rules.append(["trigger": main, "action": action])
        }
        if frames == true || (typeless && exception) {
            // Frames are documents loaded in a child frame; the page itself is left alone.
            var frame = trigger
            frame["resource-type"] = ["document"]
            frame["load-context"] = ["child-frame"]
            rules.append(["trigger": frame, "action": action])
        }
        guard !rules.isEmpty else { return .unsupported }
        return .rules(rules, important: important && !exception)
    }

    /// Pattern and options, split at the `$` that starts the options (not one inside a regex).
    static func splitOptions(_ filter: String) -> (String, [String]) {
        if filter.hasPrefix("/"), let close = filter.range(of: "/$", options: .backwards), close.lowerBound > filter.startIndex {
            return (String(filter[..<filter.index(after: close.lowerBound)]), String(filter[close.upperBound...]).split(separator: ",").map(String.init))
        }
        if filter.hasPrefix("/"), filter.hasSuffix("/"), filter.count > 2 { return (filter, []) }
        guard let dollar = filter.lastIndex(of: "$") else { return (filter, []) }
        return (String(filter[..<dollar]), filter[filter.index(after: dollar)...].split(separator: ",").map(String.init))
    }

    /// WebKit `url-filter` for an ABP pattern; nil when WebKit's regex subset can't express it.
    static func urlFilter(for pattern: String) -> String? {
        if pattern.isEmpty || pattern == "*" { return ".*" }
        if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count > 2 {
            return regexFilter(String(pattern.dropFirst().dropLast()))
        }
        var body = pattern
        var prefix = ""
        if body.hasPrefix("||") {
            body.removeFirst(2)
            prefix = hostPrefix
        } else if body.hasPrefix("|") {
            body.removeFirst()
            prefix = "^"
        } else {
            while body.hasPrefix("*") { body.removeFirst() }
        }
        var suffix = ""
        if body.hasSuffix("|") {
            body.removeLast()
            suffix = "$"
        } else {
            while body.hasSuffix("*") { body.removeLast() }
        }
        guard !body.contains("|") else { return nil }
        // Unanchored patterns need some substance, or they'd match nearly every URL.
        if prefix.isEmpty, body.filter({ $0 != "*" && $0 != "^" }).count < 3 { return nil }
        if prefix == hostPrefix, body.isEmpty { return nil }
        return prefix + regex(for: body) + suffix
    }

    /// ABP wildcard pattern → WebKit's regex subset. `^` (separator) becomes a character class;
    /// its "end of address" meaning is dropped because WebKit has no `|` alternation.
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

    /// A list's `/regex/` translated to WebKit's subset (no alternation, counted repetition, lazy
    /// quantifiers, lookarounds or backreferences; `\d` and `\w` spelled out), or nil. WebKit
    /// refuses a whole list over one unsupported regex, so anything doubtful is skipped.
    static func regexFilter(_ source: String) -> String? {
        guard source.allSatisfy(\.isASCII), !source.contains("|"), !source.contains("(?"), !source.contains("{"),
              !source.contains("*?"), !source.contains("+?"), !source.contains("??") else { return nil }
        var out = ""
        var inClass = false
        var index = source.startIndex
        while index < source.endIndex {
            let char = source[index]
            let atStart = index == source.startIndex
            let next = source.index(after: index)
            switch char {
            case "\\":
                guard next < source.endIndex else { return nil }
                let escaped = source[next]
                switch escaped {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "w": out += inClass ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
                case "/", "-", "&", "=", ":", "_", ",", "%", "!", "#", "@", "~", "'", "\"": out.append(escaped)
                case ".", "?", "+", "*", "(", ")", "[", "]", "^", "$", "\\": out += "\\\(escaped)"
                default: return nil
                }
                index = source.index(after: next)
                continue
            case "[":
                guard !inClass else { return nil }
                inClass = true
                out.append(char)
                if next < source.endIndex, source[next] == "^" { out.append("^"); index = source.index(after: next); continue }
            case "]":
                inClass = false
                out.append(char)
            case "^":
                guard atStart, !inClass else { return nil }
                out.append(char)
            case "$":
                guard next == source.endIndex, !inClass else { return nil }
                out.append(char)
            default:
                out.append(char)
            }
            index = next
        }
        guard !inClass, !out.isEmpty else { return nil }
        return out
    }

    /// Domains for a site-wide exception: `@@||example.com^$document` or `@@$ghide,domain=a.com|b.com`.
    private static func scopeDomains(_ pattern: String, fallback: [String]) -> [String]? {
        if pattern.isEmpty || pattern == "*" { return fallback }
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") || host.hasSuffix("/") { host = host.dropLast() }
        let name = host.lowercased()
        return isPlainDomain(name) ? [name] : nil
    }

    // MARK: Helpers

    /// `0.0.0.0 ads.example` / `127.0.0.1 ads.example` → the host.
    static func hostsEntry(_ line: String) -> String? {
        guard line.hasPrefix("0.0.0.0") || line.hasPrefix("127.0.0.1") else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }
        let host = fields[1].lowercased()
        guard isPlainDomain(host), host.contains("."), !["0.0.0.0", "localhost", "localhost.localdomain", "local", "broadcasthost"].contains(host) else { return nil }
        return host
    }

    /// Entities (`google.*`) and wildcards can't be WebKit domains. Included ones are dropped while
    /// plain domains remain (the filter then covers fewer sites, never more); nil when every include
    /// is one, or an exclusion is (dropping it would widen the filter).
    static func plainDomains(_ include: [String], _ exclude: [String]) -> (include: [String], exclude: [String])? {
        guard exclude.allSatisfy(isPlainDomain) else { return nil }
        let plain = include.filter(isPlainDomain)
        if plain.isEmpty && !include.isEmpty { return nil }
        return (plain, exclude)
    }

    static func isPlainDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.count <= 253 && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            && domain.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// Include domains with exclusions dropped when they don't matter (an unrelated site); nil when
    /// an exclusion narrows an include (`a.com|~b.a.com`), which WebKit can't express.
    static func narrowed(_ include: [String], excluding exclude: [String]) -> [String]? {
        if include.isEmpty { return [] }
        for excluded in exclude where include.contains(where: { excluded == $0 || excluded.hasSuffix("." + $0) }) { return nil }
        return include
    }

    /// `domain` is one of `domains` or a subdomain of one; "" covers everything.
    static func covers(_ domains: Set<String>, _ domain: String) -> Bool {
        if domains.isEmpty { return false }
        if domains.contains("") || domains.contains(domain) { return true }
        var rest = Substring(domain)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if domains.contains(String(rest)) { return true }
        }
        return false
    }

    /// The filter with its options sorted (and one option removed), to match `$badfilter`.
    private static func canonical(_ filter: String, dropping removed: String? = nil) -> String? {
        guard cosmeticParts(filter) == nil else { return nil }
        let (pattern, options) = splitOptions(filter)
        return pattern + "$" + options.map { $0.lowercased() }.filter { $0 != removed }.sorted().joined(separator: ",")
    }

    static func isSupportedSelector(_ selector: String) -> Bool {
        if case .css = CosmeticSelector.parse(selector) { return CosmeticSelector.isValidCSS(selector) }
        return false
    }
}
