import Foundation
import Testing
@testable import LilyCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct JSONValueTests {
    @Test func roundTripsNestedValues() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
        let parsed = try JSONValue.parse(value.jsonString())
        #expect(parsed == value)
        #expect(parsed["c"]?["d"]?.double == 2.5)
        #expect(parsed["b"]?.array?.count == 3)
    }

    @Test func distinguishesBoolFromNumber() throws {
        #expect(try JSONValue.parse("true") == .bool(true))
        #expect(try JSONValue.parse("1") == .number(1))
    }

    @Test func requiredParamsThrowTypedErrors() {
        let p: JSONValue = ["id": "not-a-uuid"]
        #expect(throws: IPCError.self) { try p.requiredUUID("id") }
        #expect(throws: IPCError.self) { try p.requiredString("missing") }
    }
}

@Suite struct URLResolverTests {
    let r = URLResolver(searchTemplate: "https://search.test/?q=%s")

    @Test func keepsExplicitURLs() {
        #expect(r.resolve("https://example.com/a?b=c")?.absoluteString == "https://example.com/a?b=c")
        #expect(r.resolve("about:blank")?.absoluteString == "about:blank")
    }

    @Test func promotesBareHosts() {
        #expect(r.resolve("example.com")?.absoluteString == "https://example.com")
        #expect(r.resolve("youtube.com/watch?v=x")?.absoluteString == "https://youtube.com/watch?v=x")
        #expect(r.resolve("localhost:5173")?.absoluteString == "http://localhost:5173")
        #expect(r.resolve("192.168.1.1")?.absoluteString == "http://192.168.1.1")
    }

    @Test func searchesEverythingElse() {
        #expect(r.resolve("swift concurrency")?.absoluteString == "https://search.test/?q=swift%20concurrency")
        #expect(r.resolve("a&b=c")?.absoluteString == "https://search.test/?q=a%26b%3Dc")
        #expect(r.resolve("file.txt") == nil || r.resolve("file.txt")?.host == "file.txt")
        #expect(r.resolve("   ") == nil)
    }
}

@Suite struct InjectionTests {
    @Test func repositoryManifestIsValid() throws {
        let manifest = try InjectionManifest.load(from: repoRoot.appendingPathComponent("injections/manifest.json"))
        #expect(manifest.scripts.first?.id == "runtime")
        #expect(manifest.scripts.contains { $0.id == "youtube-transcript" })
        for script in manifest.scripts {
            let file = repoRoot.appendingPathComponent("injections").appendingPathComponent(script.file)
            #expect(FileManager.default.fileExists(atPath: file.path), "missing \(script.file)")
        }
    }

    @Test func hostPatterns() {
        #expect(HostPattern.matches(host: "anything.org", pattern: "*"))
        #expect(HostPattern.matches(host: "youtube.com", patterns: ["youtube.com", "*.youtube.com"]))
        #expect(HostPattern.matches(host: "www.youtube.com", patterns: ["youtube.com", "*.youtube.com"]))
        #expect(!HostPattern.matches(host: "notyoutube.com", patterns: ["youtube.com", "*.youtube.com"]))
        #expect(!HostPattern.matches(host: "youtube.com.evil.test", patterns: ["*.youtube.com"]))
    }

    @Test func wrapAddsGuardOnlyWhenRestricted() {
        let open = ScriptRegistry.wrap("X()", id: "a", file: "a.js", matches: ["*"])
        #expect(open.hasPrefix("X()"))
        #expect(open.contains("sourceURL=lily-injection://a.js"))
        let guarded = ScriptRegistry.wrap("X()", id: "b", file: "b.js", matches: ["*.youtube.com"])
        #expect(guarded.contains(#"["*.youtube.com"]"#))
        #expect(guarded.contains("if (!ok) return;"))
    }

    @Test func rejectsUnsafeManifest() {
        let bad = InjectionManifest(version: 1, contentWorld: "W", scripts: [
            .init(id: "runtime", file: "../escape.js", injectionTime: .documentStart, mainFrameOnly: false, matches: ["*"]),
        ])
        #expect(throws: IPCError.self) { try bad.validate() }
    }

    @MainActor @Test func registryCompilesAllModules() throws {
        let registry = try ScriptRegistry(manifestURL: repoRoot.appendingPathComponent("injections/manifest.json"))
        #expect(registry.scripts.count == registry.manifest.scripts.count)
        #expect(registry.scripts.first?.injectionTime == .documentStart)
    }
}

@Suite @MainActor struct IPCRouterTests {
    func envelope(_ type: String, kind: IPCEnvelope.Kind = .request, payload: JSONValue = .null) -> String {
        (try? JSONValue.from(IPCEnvelope(kind: kind, type: type, payload: payload)).jsonString()) ?? ""
    }

    func decode(_ s: String) throws -> IPCReply { try JSONDecoder().decode(IPCReply.self, from: Data(s.utf8)) }

    let page = IPCSource.page(tabID: UUID(), isMainFrame: true, url: URL(string: "https://a.example"))

    @Test func dispatchesAndEnforcesSources() async throws {
        let router = IPCRouter()
        router.on("echo", from: [.page]) { _, p in p }
        let ok = try decode(await router.dispatch(rawBody: envelope("echo", payload: ["x": 1]), source: page))
        #expect(ok.ok && ok.result?["x"]?.int == 1)

        // A route that admits no source kinds can't be called by pages.
        router.on("locked", from: []) { _, _ in .null }
        let blocked = try decode(await router.dispatch(rawBody: envelope("locked"), source: page))
        #expect(!blocked.ok && blocked.error?.code == "forbidden")
    }

    @Test func reportsMalformedAndUnknown() async throws {
        let router = IPCRouter()
        #expect(try decode(await router.dispatch(rawBody: 42, source: page)).error?.code == "malformed")
        #expect(try decode(await router.dispatch(rawBody: "{nope", source: page)).error?.code == "malformed")
        #expect(try decode(await router.dispatch(rawBody: envelope("missing"), source: page)).error?.code == "unknown_type")
    }

    @Test func unhandledEventsGoToFallback() async throws {
        let router = IPCRouter()
        var seen: String?
        router.onUnhandledEvent = { _, type, _ in seen = type }
        let reply = try decode(await router.dispatch(rawBody: envelope("custom.thing", kind: .event), source: page))
        #expect(reply.ok)
        #expect(seen == "custom.thing")
    }

    @Test func handlerErrorsAreMapped() async throws {
        let router = IPCRouter()
        router.on("fail", from: [.page]) { _, _ in throw IPCError.notFound("nope") }
        let reply = try decode(await router.dispatch(rawBody: envelope("fail"), source: page))
        #expect(reply.error == IPCError.notFound("nope"))
    }
}

@Suite struct SecurityHardeningTests {
    @Test func packagedBuildsIgnoreResourceOverrides() {
        let bundle = URL(fileURLWithPath: "/Applications/Lily.app/Contents/Resources")
        let paths = AppPaths.resolve(environment: ["LILY_ROOT": repoRoot.path], packagedResources: bundle)
        #expect(paths.root.path == "/Applications/Lily.app/Contents/Resources/Lily")
        // Development builds still honour the override.
        #expect(AppPaths.resolve(environment: ["LILY_ROOT": repoRoot.path], packagedResources: nil).root == AppPaths(root: repoRoot).root)
    }

    @Test func onlyNonWebSchemesOpenExternally() {
        #expect(Tab.opensExternally(URL(string: "zoommtg://zoom.us/join")!))
        #expect(Tab.opensExternally(URL(string: "smb://server/share")!))
        #expect(Tab.opensExternally(URL(string: "mailto:a@b.c")!))
        #expect(!Tab.opensExternally(URL(string: "https://example.com")!))
        #expect(!Tab.opensExternally(URL(string: "about:blank")!))
    }
}
