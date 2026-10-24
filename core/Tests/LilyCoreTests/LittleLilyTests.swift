import Foundation
import Testing
import WebKit
@testable import LilyCore

/// Moving a live tab between windows (Little Lily → Open in Lily): out of one store without being
/// torn down, into another's current space with its routes, keeping the same web view.
@Suite @MainActor struct LittleLilyTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func stores(persistent: Bool = false) throws -> (little: TabStore, main: TabStore, mainRouter: IPCRouter, factory: WebViewFactory) {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        let factory = WebViewFactory(registry: registry, dataStore: persistent ? .default() : .nonPersistent())
        let mainRouter = IPCRouter()
        return (TabStore(factory: factory, router: IPCRouter()), TabStore(factory: factory, router: mainRouter), mainRouter, factory)
    }

    @Test func detachKeepsTheTabAlive() throws {
        let (little, _, _, _) = try stores()
        let tab = little.create(url: nil)
        let page = tab.webView
        let detached = try #require(little.detach(tab.id))
        #expect(detached === tab && little.tabs.isEmpty && little.activeID == nil)
        #expect(little.recentlyClosed.isEmpty)        // it moved; it wasn't closed
        #expect(tab.hasWebView && tab.webView === page) // not torn down
        #expect(little.detach(UUID()) == nil)
    }

    @Test func adoptPutsItAfterTheActiveTabInTheCurrentSpace() throws {
        let (little, main, mainRouter, _) = try stores()
        let first = main.create(url: nil)
        let last = main.create(url: nil, activate: false, nextToActive: false)
        main.activate(first.id)
        let work = main.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF", activate: false)
        _ = work

        let tab = little.create(url: nil, pinned: true)
        let page = tab.webView
        main.adopt(try #require(little.detach(tab.id)))
        #expect(main.tabs.map(\.id) == [first.id, tab.id, last.id])
        #expect(main.activeID == tab.id && tab.spaceID == main.currentSpaceID && !tab.isPinned)
        #expect(tab.router === mainRouter)             // its pages now talk to the main window
        #expect(tab.webView === page)                  // same page, no reload
        #expect(tab.delegate === main.tabDelegate)
    }

    @Test func adoptingIntoSeparateLoginsMovesItToThatStore() async throws {
        let (little, main, _, factory) = try stores(persistent: true)
        var space = main.currentSpace
        space.separateLogins = true
        main.updateSpace(space)

        let tab = little.create(url: nil)
        let page = tab.webView
        main.adopt(try #require(little.detach(tab.id)))
        #expect(tab.webView !== page)
        #expect(tab.webView.configuration.websiteDataStore === factory.dataStore(forSpace: space.id))
        await factory.removeSpaceData(space.id)
    }
}
