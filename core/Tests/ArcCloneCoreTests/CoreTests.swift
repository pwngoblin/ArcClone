import Foundation
import Testing
@testable import ArcCloneCore

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
        #expect(open.contains("sourceURL=arc-injection://a.js"))
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

    @Test func dispatchesAndEnforcesSources() async throws {
        let router = IPCRouter()
        router.on("echo", from: [.chrome]) { _, p in p }
        let ok = try decode(await router.dispatch(rawBody: envelope("echo", payload: ["x": 1]), source: .chrome))
        #expect(ok.ok && ok.result?["x"]?.int == 1)

        let blocked = try decode(await router.dispatch(rawBody: envelope("echo"), source: .page(tabID: UUID(), isMainFrame: true, url: nil)))
        #expect(!blocked.ok && blocked.error?.code == "forbidden")
    }

    @Test func reportsMalformedAndUnknown() async throws {
        let router = IPCRouter()
        #expect(try decode(await router.dispatch(rawBody: 42, source: .chrome)).error?.code == "malformed")
        #expect(try decode(await router.dispatch(rawBody: "{nope", source: .chrome)).error?.code == "malformed")
        #expect(try decode(await router.dispatch(rawBody: envelope("missing"), source: .chrome)).error?.code == "unknown_type")
    }

    @Test func unhandledEventsGoToFallback() async throws {
        let router = IPCRouter()
        var seen: String?
        router.onUnhandledEvent = { _, type, _ in seen = type }
        let reply = try decode(await router.dispatch(rawBody: envelope("custom.thing", kind: .event), source: .chrome))
        #expect(reply.ok)
        #expect(seen == "custom.thing")
    }

    @Test func handlerErrorsAreMapped() async throws {
        let router = IPCRouter()
        router.on("fail", from: [.chrome]) { _, _ in throw IPCError.notFound("nope") }
        let reply = try decode(await router.dispatch(rawBody: envelope("fail"), source: .chrome))
        #expect(reply.error == IPCError.notFound("nope"))
    }
}

@Suite @MainActor struct SchemeHandlerTests {
    @Test func blocksPathTraversal() {
        let h = UISchemeHandler(root: URL(fileURLWithPath: "/tmp/ui/dist"))
        #expect(h.fileURL(for: URL(string: "arc-ui://app/")!)?.path == "/tmp/ui/dist/index.html")
        #expect(h.fileURL(for: URL(string: "arc-ui://app/assets/a.js")!)?.path == "/tmp/ui/dist/assets/a.js")
        #expect(h.fileURL(for: URL(string: "arc-ui://app/../../etc/passwd")!) == nil)
        #expect(h.fileURL(for: URL(string: "arc-ui://app/%2E%2E/secret")!) == nil)
    }
}

@Suite struct SecurityHardeningTests {
    @Test func packagedBuildsIgnoreResourceOverrides() {
        let bundle = URL(fileURLWithPath: "/Applications/ArcClone.app/Contents/Resources")
        let paths = AppPaths.resolve(environment: ["ARCCLONE_ROOT": repoRoot.path], packagedResources: bundle)
        #expect(paths.root.path == "/Applications/ArcClone.app/Contents/Resources/ArcClone")
        // Development builds still honour the override.
        #expect(AppPaths.resolve(environment: ["ARCCLONE_ROOT": repoRoot.path], packagedResources: nil).root == AppPaths(root: repoRoot).root)
    }

    @Test func chromeCSPCoversDirectivesDefaultSrcMisses() {
        let csp = UISchemeHandler.contentSecurityPolicy
        for directive in ["base-uri 'none'", "form-action 'none'", "frame-src 'none'", "object-src 'none'", "script-src 'self' arc-ui:"] {
            #expect(csp.contains(directive), "missing \(directive)")
        }
        #expect(!csp.contains("unsafe-eval"))
    }

    @Test func onlyNonWebSchemesOpenExternally() {
        #expect(Tab.opensExternally(URL(string: "zoommtg://zoom.us/join")!))
        #expect(Tab.opensExternally(URL(string: "smb://server/share")!))
        #expect(Tab.opensExternally(URL(string: "mailto:a@b.c")!))
        #expect(!Tab.opensExternally(URL(string: "https://example.com")!))
        #expect(!Tab.opensExternally(URL(string: "about:blank")!))
    }
}
