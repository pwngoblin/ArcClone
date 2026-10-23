import Foundation

/// Mirrors `injections/manifest.json`.
public struct InjectionManifest: Codable, Sendable, Equatable {
    public struct Script: Codable, Sendable, Equatable {
        public enum InjectionTime: String, Codable, Sendable {
            case documentStart
            case documentEnd
        }

        public var id: String
        public var file: String
        public var injectionTime: InjectionTime
        public var mainFrameOnly: Bool
        public var matches: [String]
    }

    public var version: Int
    public var contentWorld: String
    public var scripts: [Script]

    public static func load(from url: URL) throws -> InjectionManifest {
        let manifest = try JSONDecoder().decode(InjectionManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        var seen = Set<String>()
        for script in scripts {
            guard seen.insert(script.id).inserted else {
                throw IPCError.malformed("Duplicate injection id \(script.id)")
            }
            // ids, paths and patterns end up inside generated JavaScript (ScriptRegistry.wrap), so
            // they must match a strict grammar: no quotes, newlines, slashes outside the path, or "..".
            guard script.id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
                throw IPCError.malformed("Injection id '\(script.id)' is not allowed")
            }
            guard script.file.range(of: #"^modules/[a-z0-9][a-z0-9-]{0,63}\.js$"#, options: .regularExpression) != nil else {
                throw IPCError.malformed("Injection \(script.id) has an unsafe path")
            }
            for pattern in script.matches where pattern.range(of: #"^(\*|(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)*)$"#, options: .regularExpression) == nil {
                throw IPCError.malformed("Injection \(script.id) has an invalid match pattern")
            }
            guard !script.matches.isEmpty else {
                throw IPCError.malformed("Injection \(script.id) has no match patterns")
            }
        }
        guard scripts.first?.id == "runtime" else {
            throw IPCError.malformed("The 'runtime' injection must be listed first")
        }
    }
}

/// Host match patterns: `*` (any host), `example.com` (exact), `*.example.com` (subdomains only).
public enum HostPattern {
    public static func matches(host: String, pattern: String) -> Bool {
        let host = host.lowercased()
        let pattern = pattern.lowercased()
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            return host.hasSuffix(String(pattern.dropFirst(1)))
        }
        return host == pattern
    }

    public static func matches(host: String, patterns: [String]) -> Bool {
        patterns.contains { matches(host: host, pattern: $0) }
    }
}
