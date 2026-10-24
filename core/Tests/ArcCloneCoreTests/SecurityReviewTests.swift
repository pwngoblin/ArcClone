import Foundation
import Testing
import WebKit
@testable import ArcCloneCore

@Suite @MainActor struct SecurityReviewTests {
    let page = IPCSource.page(tabID: UUID(), isMainFrame: true, url: URL(string: "https://a.example"))

    func send(_ router: IPCRouter, _ body: String, from source: IPCSource) async throws -> IPCReply {
        try JSONDecoder().decode(IPCReply.self, from: Data(await router.dispatch(rawBody: body, source: source).utf8))
    }

    func envelope(_ payload: JSONValue = .null) throws -> String {
        try JSONValue.from(IPCEnvelope(kind: .event, type: "ping", payload: payload)).jsonString()
    }

    @Test func pagesAreRateLimitedPerTab() async throws {
        let router = IPCRouter()
        router.on("ping", from: [.page]) { _, _ in .null }
        var accepted = 0
        for _ in 0..<100 where try await send(router, try envelope(), from: page).ok { accepted += 1 }
        #expect(accepted == Int(IPCRouter.burst))
        let other = IPCSource.page(tabID: UUID(), isMainFrame: true, url: nil)
        #expect(try await send(router, try envelope(), from: other).ok) // other tabs unaffected
    }

    @Test func oversizedMessagesAreRefusedUnread() async throws {
        let router = IPCRouter()
        router.on("ping", from: [.page]) { _, _ in .null }
        let big = try envelope(.string(String(repeating: "x", count: IPCRouter.maxMessageBytes)))
        #expect(try await send(router, big, from: page).error?.code == "malformed")
    }

    /// Deeply nested JSON must be rejected, not crash the app with a stack overflow.
    @Test func nestingBombsAreRejected() async throws {
        let router = IPCRouter()
        router.on("ping", from: [.page]) { _, _ in .null }
        let bomb = #"{"v":1,"id":"x","kind":"event","type":"ping","payload":"# + String(repeating: "[", count: 100_000)
            + String(repeating: "]", count: 100_000) + "}"
        let reply = try await send(router, bomb, from: page)
        #expect(!reply.ok)
    }

    @Test func userAgentIsPlainSafari() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let factory = WebViewFactory(registry: try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json")))
        #expect(!factory.applicationNameForUserAgent.contains("ArcClone"))
        let bridge = ScriptMessageBridge(name: "t", contentWorld: .world(name: "T"), router: IPCRouter()) { _ in nil }
        #expect(factory.makeConfiguration(bridge: bridge).mediaTypesRequiringUserActionForPlayback.contains(.audio))
    }

    @Test func tamperedExtensionListLoadsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-extlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Someone without the key writes a list pointing at their own "extension".
        let forged = try JSONEncoder().encode([InstalledExtension(id: "evil", bookmark: Data([1, 2, 3]), enabled: true,
                                                                   grantedPermissions: ["tabs"], grantedPatterns: ["<all_urls>"])])
        try forged.write(to: dir.appendingPathComponent("extensions.sealed"))
        let library = ExtensionLibrary(directory: dir, keys: InMemoryKeyStore())
        await library.loadAll()
        #expect(library.installed.isEmpty && library.ready.isEmpty)
        #expect(library.lastError != nil)
    }
}
