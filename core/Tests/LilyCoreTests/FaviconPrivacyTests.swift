import AppKit
import Foundation
import Testing
@testable import LilyCore

/// Serves a small PNG for any request and counts them, so a test can prove a view didn't ask.
final class IconServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URL] = []
    static let png: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.url!)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct FaviconPrivacyTests {
    private let page = URL(string: "https://news.example/story/1")!
    private let icon = URL(string: "https://news.example/favicon.ico")!

    private func loader() -> FaviconLoader {
        let config = FaviconLoader.ephemeral
        config.protocolClasses = [IconServer.self]
        IconServer.requests = []
        return FaviconLoader(configuration: config)
    }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func listsNeverContactTheSitesInThem() {
        let icons = loader()
        // What History, suggestions and sleeping tabs ask for: kept icons only.
        #expect(icons.icon(forPage: page) == nil)
        #expect(IconServer.requests.isEmpty)
    }

    @Test func anOpenPageKeepsItsIconForLaterWithoutAskingAgain() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = InMemoryKeyStore()
        let icons = loader()
        await icons.load(directory: dir, keys: keys)
        #expect(await icons.fetch(icon, forPage: page, remember: true) != nil)
        #expect(IconServer.requests == [icon])
        _ = await icons.fetch(icon, forPage: page, remember: true) // once a session is enough
        #expect(IconServer.requests.count == 1)
        try await Task.sleep(for: .seconds(5.5)) // the debounced save

        let later = loader()
        await later.load(directory: dir, keys: keys)
        #expect(later.icon(forPage: URL(string: "https://news.example/other")!) != nil)
        #expect(IconServer.requests.isEmpty)
        let raw = try Data(contentsOf: dir.appendingPathComponent("favicons.sealed"))
        #expect(raw.range(of: Data("news.example".utf8)) == nil) // encrypted, site names included
    }

    @Test func privateWindowsShowIconsButNeverKeepThem() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = InMemoryKeyStore()
        let icons = loader()
        await icons.load(directory: dir, keys: keys)
        #expect(await icons.fetch(icon, forPage: page, remember: false) != nil)
        try await Task.sleep(for: .seconds(5.5))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("favicons.sealed").path))
    }

    @Test func iconsGoWithTheHistoryThatRevealsThem() async throws {
        let icons = loader()
        _ = await icons.fetch(icon, forPage: page, remember: true)
        _ = await icons.fetch(URL(string: "https://mail.example/favicon.ico")!, forPage: URL(string: "https://mail.example/")!, remember: true)
        icons.forget(.sites(["news.example"]))
        #expect(icons.icon(forPage: page) == nil)
        #expect(icons.icon(forPage: URL(string: "https://mail.example/")!) != nil)
        icons.forget(.all)
        #expect(icons.icon(forPage: URL(string: "https://mail.example/")!) == nil)
    }

    @Test func historyReportsWhatItForgets() {
        let history = History(directory: nil)
        var forgotten: [History.Forgotten] = []
        history.onForget = { forgotten.append($0) }
        history.record(url: URL(string: "https://a.example/1")!, title: "A")
        history.record(url: URL(string: "https://b.example/1")!, title: "B")
        history.record(url: URL(string: "https://b.example/2")!, title: "B2")
        let bOne = history.visits.first { $0.url.path == "/1" && $0.url.host == "b.example" }!.id
        history.remove([bOne])                       // b.example still has a visit
        #expect(forgotten.isEmpty)
        let aOne = history.visits.first { $0.url.host == "a.example" }!.id
        history.remove([aOne])                       // a.example is gone entirely
        #expect(forgotten == [.sites(["a.example"])])
        history.clear()
        #expect(forgotten.last == .all)
    }
}
