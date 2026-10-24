import Foundation

/// A static review of an extension's files before it's installed: what it may run, what it can
/// reach, and where it sends data. Anything that would let it load code from the network blocks
/// installation; risky but common patterns are shown to the user as warnings.
struct ExtensionAudit: Sendable, Equatable {
    enum Severity: Int, Sendable, Comparable {
        case info, warning, blocked
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    struct Finding: Sendable, Hashable {
        let severity: Severity
        let title: String
        /// Where it was seen (files, hosts, permissions), shortened for display.
        let detail: String
    }

    let findings: [Finding]
    var isBlocked: Bool { findings.contains { $0.severity == .blocked } }

    /// Analytics and error-reporting services that extensions commonly phone home to.
    static let telemetryHosts = [
        "google-analytics.com", "googletagmanager.com", "analytics.google.com", "doubleclick.net", "mixpanel.com",
        "segment.io", "segment.com", "amplitude.com", "sentry.io", "bugsnag.com", "hotjar.com", "datadoghq.com",
        "newrelic.com", "nr-data.net", "posthog.com", "heap.io", "heapanalytics.com", "app-measurement.com",
        "firebaseio.com", "firebaselogging.googleapis.com", "clarity.ms", "fullstory.com", "logrocket.com", "rollbar.com",
        "yandex.ru/metrika", "mc.yandex.ru", "statcounter.com", "matomo.cloud", "plausible.io", "countly.com",
    ]

    /// Permissions that reach beyond the pages the extension is used on.
    static let sensitivePermissions: Set<String> = [
        "cookies", "history", "webRequest", "webRequestBlocking", "debugger", "management", "proxy", "privacy",
        "declarativeNetRequestFeedback", "clipboardRead", "downloads", "tabCapture", "desktopCapture", "nativeMessaging",
        "browsingData", "topSites", "bookmarks", "pageCapture", "identity", "webNavigation", "scripting",
    ]

    private static let codeExtensions: Set<String> = ["js", "mjs", "cjs", "html", "htm"]
    private static let codeChecks: [(Severity, String, String)] = [
        (.blocked, "Loads scripts from the internet", #"<script[^>]+src\s*=\s*["']?(https?:)?//"#),
        (.blocked, "Imports scripts from the internet", #"importScripts\(\s*["'`](https?:)?//"#),
        (.blocked, "Imports modules from the internet", #"import\s*\(\s*["'`]https?://"#),
        (.warning, "Evaluates strings as code (eval)", #"(^|[^.\w$])eval\s*\("#),
        (.warning, "Builds functions from strings (new Function)", #"new\s+Function\s*\("#),
        (.warning, "Runs strings as code in timers", #"set(Timeout|Interval)\s*\(\s*["'`]"#),
        (.warning, "Talks to native apps on your Mac", #"(sendNativeMessage|connectNative)\s*\("#),
        (.info, "Writes HTML into pages (innerHTML / document.write)", #"\.innerHTML\s*=|\.outerHTML\s*=|document\.write\s*\("#),
        (.info, "Runs WebAssembly", #"WebAssembly\.(instantiate|compile)"#),
    ]
    /// Compiled once: compiling a pattern per file (or per line) was most of an audit's time.
    private static let compiledChecks = codeChecks.map { severity, title, pattern in
        (severity, title, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
    }
    private static let hostPattern = try! NSRegularExpression(pattern: #"https?://([a-z0-9-]+(?:\.[a-z0-9-]+)+)"#, options: [.caseInsensitive])
    /// Lines that send something: fetch, beacons, XHR, pixels.
    private static let sendPattern = try! NSRegularExpression(pattern: #"fetch\s*\(|sendBeacon|XMLHttpRequest|\.open\s*\(|\.src\s*=|axios|\$\.(ajax|get|post)|new\s+Image\s*\("#)
    /// Hosts kept per file for the "Mentions these servers" note; telemetry is checked on every URL.
    private static let maxHostsPerFile = 2_000

    static func scan(_ package: ExtensionPackage) -> ExtensionAudit {
        var findings: [Finding] = []
        guard let manifest = ExtensionManifest.parse(package) else {
            return ExtensionAudit(findings: [Finding(severity: .blocked, title: "manifest.json isn't valid", detail: "manifest.json")])
        }
        findings += review(manifest: manifest)

        var hits: [String: [String]] = [:]
        var hosts = Set<String>()
        var telemetry = Set<String>()
        for (path, contents) in package.files.sorted(by: { $0.key < $1.key }) {
            guard let ext = path.split(separator: ".").last.map({ $0.lowercased() }), codeExtensions.contains(ext) else { continue }
            // One UTF-16 string per file, shared by every pattern (Swift strings are re-bridged per call).
            let text = NSString(data: contents, encoding: NSUTF8StringEncoding) ?? String(decoding: contents, as: UTF8.self) as NSString
            let all = NSRange(location: 0, length: text.length)
            for (_, title, regex) in compiledChecks where regex.firstMatch(in: text as String, range: all) != nil {
                hits[title, default: []].append(path)
            }
            let found = urls(in: text)
            hosts.formUnion(found.hosts)
            telemetry.formUnion(found.telemetry)
        }
        for (severity, title, _) in codeChecks {
            if let files = hits[title] { findings.append(Finding(severity: severity, title: title, detail: list(files))) }
        }
        if !telemetry.isEmpty {
            findings.append(Finding(severity: .warning, title: "Sends data to analytics or error-reporting services", detail: list(telemetry.sorted())))
        }
        let others = hosts.subtracting(telemetry).filter { !ignoredHosts.contains($0) }
        if !others.isEmpty { findings.append(Finding(severity: .info, title: "Mentions these servers", detail: list(others.sorted(), limit: 8))) }
        return ExtensionAudit(findings: findings.sorted { $0.severity > $1.severity })
    }

    // MARK: Manifest

    static func review(manifest: ExtensionManifest) -> [Finding] {
        var findings: [Finding] = []
        if manifest.manifestVersion < 3 {
            findings.append(Finding(severity: .info, title: "Uses the older Manifest V2 format", detail: "manifest_version \(manifest.manifestVersion)"))
        }

        // A content security policy that allows eval or remote scripts lets the extension run code
        // that was never part of what's audited and pinned here.
        var policies: [(String, String)] = []
        if let pages = manifest.contentSecurityPolicy?.extensionPages { policies.append(("extension pages", pages)) }
        if let sandbox = manifest.contentSecurityPolicy?.sandbox { policies.append(("sandbox", sandbox)) }
        for (scope, policy) in policies {
            let scripts = directive("script-src", in: policy) ?? directive("default-src", in: policy) ?? ""
            let remote = scripts.split(separator: " ").filter { source in
                let s = source.lowercased()
                return s.hasPrefix("http:") || s.hasPrefix("https:") || s == "*" || s.hasPrefix("*.") || s == "data:" || s == "blob:"
                    || (s.contains(".") && !s.hasPrefix("'"))
            }
            let unsafe = ["'unsafe-eval'", "'unsafe-inline'"].filter { scripts.lowercased().contains($0) }
            guard !remote.isEmpty || !unsafe.isEmpty else { continue }
            // Sandboxed pages have no extension APIs and no access to your pages.
            findings.append(Finding(severity: scope == "sandbox" ? .warning : .blocked,
                                    title: scope == "sandbox" ? "Sandboxed pages may run unchecked code"
                                                              : "Its security policy allows code from outside the extension",
                                    detail: (unsafe + remote.map(String.init)).joined(separator: ", ")))
        }

        let sensitive = (manifest.permissions + manifest.optionalPermissions).filter(sensitivePermissions.contains)
        if !sensitive.isEmpty { findings.append(Finding(severity: .warning, title: "Asks for sensitive permissions", detail: list(sensitive.sorted()))) }
        let hosts = manifest.allHostPatterns + manifest.contentScripts.flatMap(\.matches)
        if hosts.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }) {
            findings.append(Finding(severity: .warning, title: "Can read and change every website", detail: "host permissions"))
        }
        if let matches = manifest.externallyConnectable?.matches, !matches.isEmpty {
            findings.append(Finding(severity: .warning, title: "Websites can send it messages", detail: list(matches)))
        }
        if let update = manifest.updateURL {
            findings.append(Finding(severity: .info, title: "Has an update address; ArcClone never updates it automatically",
                                    detail: URL(string: update)?.host ?? "update_url"))
        }
        return findings
    }

    static func directive(_ name: String, in policy: String) -> String? {
        for part in policy.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(name + " ") || trimmed.lowercased() == name { return String(trimmed.dropFirst(name.count)) }
        }
        return nil
    }

    // MARK: Helpers

    /// Namespace and documentation hosts that appear in code without being contacted.
    private static let ignoredHosts: Set<String> = [
        "www.w3.org", "w3.org", "localhost", "example.com", "www.example.com", "schema.org", "json-schema.org",
        "developer.mozilla.org", "developer.chrome.com", "github.com", "reactjs.org", "fb.me", "www.apache.org",
        "opensource.org", "mozilla.org", "creativecommons.org", "unicode.org", "tc39.es", "npms.io", "feross.org",
    ]

    static func isTelemetry(_ host: String) -> Bool { telemetryHosts.contains { host == $0 || host.hasSuffix("." + $0) } }

    /// Telemetry hosts on lines that actually send something (fetch, beacons, XHR, pixels). Ad
    /// blockers list the same hosts as things to block; those lines don't make requests.
    static func telemetryCalls(in text: String) -> Set<String> { urls(in: text as NSString).telemetry }

    static func remoteHosts(in text: String) -> Set<String> { urls(in: text as NSString).hosts }

    /// One pass over the URLs in `text`: the hosts it mentions (the first `maxHostsPerFile`), and
    /// the telemetry hosts on lines that send something.
    private static func urls(in text: NSString) -> (hosts: Set<String>, telemetry: Set<String>) {
        var hosts = Set<String>(), telemetry = Set<String>()
        var count = 0
        hostPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            let host = text.substring(with: match.range(at: 1)).lowercased()
            count += 1
            if count <= maxHostsPerFile { hosts.insert(host) }
            if isTelemetry(host), !telemetry.contains(host),
               sendPattern.firstMatch(in: text as String, range: text.lineRange(for: match.range)) != nil {
                telemetry.insert(host)
            }
        }
        return (hosts, telemetry)
    }

    private static func list(_ items: [String], limit: Int = 4) -> String {
        items.prefix(limit).joined(separator: ", ") + (items.count > limit ? " and \(items.count - limit) more" : "")
    }
}
