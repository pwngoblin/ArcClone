import Foundation
import Testing
@testable import LilyCore

@Suite struct PagePayloadTests {
    let origin = URL(string: "https://news.example")!

    @Test func metadataIsBoundToTheFrameOrigin() throws {
        let ok = try PagePayload.metadata(.init(url: "https://news.example/a?b", title: "  Hi  ", favicon: "https://cdn.example/f.ico",
                                                themeColor: "#112233"), origin: origin)
        #expect(ok.title == "Hi" && ok.favicon?.host == "cdn.example" && ok.themeColor == "#112233")
        // A frame can't claim to be another site, or another scheme/port of the same host.
        for spoof in ["https://bank.example/", "http://news.example/", "https://news.example:8443/"] {
            #expect(throws: IPCError.self) { try PagePayload.metadata(.init(url: spoof), origin: origin) }
        }
        // No origin from WebKit (an opaque frame): nothing to check against, so refused.
        #expect(throws: IPCError.self) { try PagePayload.metadata(.init(url: "https://news.example/"), origin: nil) }
        #expect(throws: IPCError.self) { try PagePayload.sameOrigin("https://news.example/", origin: nil) }
    }

    @Test func untrustedFieldsAreSanitized() throws {
        let m = try PagePayload.metadata(.init(url: "https://news.example/", title: String(repeating: "x", count: 5000),
                                               favicon: "javascript:alert(1)", themeColor: "red; background:url(x)"), origin: origin)
        #expect(m.title?.count == PagePayload.maxTitle)
        #expect(m.favicon == nil && m.themeColor == nil)
        let s = try PagePayload.selection(.init(url: "https://news.example/", text: String(repeating: "y", count: 50_000)), origin: origin)
        #expect(s.text.count == PagePayload.maxSelection)
    }

    @Test func videoEventsOnlyFromYouTubeWithValidIDs() throws {
        let yt = URL(string: "https://www.youtube.com")!
        #expect(try PagePayload.videoID(.init(videoId: "dQw4w9WgXcQ", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), origin: yt) == "dQw4w9WgXcQ")
        #expect(throws: IPCError.self) { try PagePayload.videoID(.init(videoId: "<script>", url: "https://www.youtube.com/"), origin: yt) }
        #expect(throws: IPCError.self) { try PagePayload.videoID(.init(videoId: "dQw4w9WgXcQ", url: "https://evil.example/"), origin: origin) }
    }

    @Test func originURLComesFromSecurityOriginParts() {
        #expect(IPCSource.originURL(protocol: "https", host: "a.example", port: 0)?.absoluteString == "https://a.example")
        #expect(IPCSource.originURL(protocol: "http", host: "localhost", port: 5173)?.absoluteString == "http://localhost:5173")
        #expect(IPCSource.originURL(protocol: "", host: "", port: 0) == nil)
    }
}

@Suite @MainActor struct TypedRouteTests {
    @Test func malformedPayloadsAreRejected() async throws {
        let router = IPCRouter()
        router.on("page.didChange", from: [.page], as: PagePayload.DidChange.self) { _, p in .string(p.url) }
        let source = IPCSource.page(tabID: UUID(), isMainFrame: true, url: URL(string: "https://a.example"))
        func send(_ payload: JSONValue) async throws -> IPCReply {
            let body = try JSONValue.from(IPCEnvelope(kind: .event, type: "page.didChange", payload: payload)).jsonString()
            return try JSONDecoder().decode(IPCReply.self, from: Data(await router.dispatch(rawBody: body, source: source).utf8))
        }
        #expect(try await send(["url": "https://a.example/"]).ok)
        #expect(try await send(["url": 42]).error?.code == "invalid_params")
        #expect(try await send(["title": "no url"]).error?.code == "invalid_params")
    }
}

@Suite struct SessionFormatTests {
    @Test func oldSessionsWithoutBookmarksStillDecode() throws {
        let old = #"{"tabs":[{"url":"https://a.example","title":"A","pinned":false}],"activeIndex":0}"#
        let session = try JSONDecoder().decode(SessionStore.Session.self, from: Data(old.utf8))
        #expect(session.tabs.first?.bookmark == nil)
    }
}
