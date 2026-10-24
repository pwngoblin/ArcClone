import Foundation
import Testing
import WebKit
@testable import LilyCore

/// Spaces with Separate logins: their own website data store, applied to new, moved and
/// already-open tabs, kept across sessions, and removed with the space.
@Suite @MainActor struct WorkspaceTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func makeStore(persistent: Bool = true) throws -> (TabStore, WebViewFactory) {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        let factory = WebViewFactory(registry: registry, dataStore: persistent ? .default() : .nonPersistent())
        return (TabStore(factory: factory, router: IPCRouter()), factory)
    }

    private func store(of tab: Tab) -> WKWebsiteDataStore { tab.webView.configuration.websiteDataStore }

    @Test func separateLoginsGetTheirOwnStore() async throws {
        let (tabs, factory) = try makeStore()
        let shared = tabs.create(url: nil)
        let work = tabs.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF", separateLogins: true)
        let dev = tabs.addSpace(name: "Dev", symbol: "star.fill", color: "#0A84FF", separateLogins: true)
        let inDev = tabs.create(url: nil)
        tabs.switchSpace(to: work.id)
        let inWork = tabs.create(url: nil)

        #expect(store(of: shared) === factory.dataStore)
        #expect(store(of: inWork) === factory.dataStore(forSpace: work.id) && store(of: inWork) !== factory.dataStore)
        #expect(store(of: inDev) !== store(of: inWork))
        #expect(factory.dataStore(forSpace: work.id) === factory.dataStore(forSpace: work.id)) // one store per space
        await factory.removeSpaceData(work.id)
        await factory.removeSpaceData(dev.id)
    }

    @Test func privateWindowsKeepOneThrowawayStore() throws {
        let (tabs, factory) = try makeStore(persistent: false)
        let space = tabs.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF", separateLogins: true)
        #expect(!factory.isolatesSpaces)
        #expect(factory.dataStore(forSpace: space.id) === factory.dataStore)
    }

    @Test func switchingTheToggleMovesOpenTabsToTheNewStore() async throws {
        let (tabs, factory) = try makeStore()
        let tab = tabs.create(url: nil)
        let before = tab.webView
        #expect(store(of: tab) === factory.dataStore)

        var space = tabs.currentSpace
        space.separateLogins = true
        tabs.updateSpace(space)
        #expect(tab.webView !== before)
        #expect(store(of: tab) === factory.dataStore(forSpace: space.id) && store(of: tab) !== factory.dataStore)

        let isolated = tab.webView
        space.name = "Renamed" // not a store change: the page stays as it is
        tabs.updateSpace(space)
        #expect(tab.webView === isolated)

        space.separateLogins = false
        tabs.updateSpace(space)
        #expect(store(of: tab) === factory.dataStore)
        await factory.removeSpaceData(space.id)
    }

    @Test func movingATabBetweenStoresReloadsItThere() async throws {
        let (tabs, factory) = try makeStore()
        let home = tabs.currentSpaceID
        let tab = tabs.create(url: nil)
        let plain = tabs.addSpace(name: "Plain", symbol: "star.fill", color: "#0A84FF", activate: false)
        let work = tabs.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF", separateLogins: true, activate: false)

        let original = tab.webView
        tabs.moveTab(tab.id, toSpace: plain.id) // same shared store: nothing reloads
        #expect(tab.webView === original)
        tabs.moveTab(tab.id, toSpace: work.id)
        #expect(tab.webView !== original && store(of: tab) === factory.dataStore(forSpace: work.id))
        tabs.moveTab(tab.id, toSpace: home)
        #expect(store(of: tab) === factory.dataStore)
        await factory.removeSpaceData(work.id)
    }

    @Test func sessionsKeepTheToggleAndOlderSessionsStillLoad() async throws {
        var space = Space(name: "Work", symbol: "briefcase.fill")
        space.separateLogins = true
        let session = SessionStore.Session(tabs: [.init(url: URL(string: "https://mail.example/")!, title: "Mail", pinned: false, bookmark: nil, space: space.id)],
                                           activeIndex: 0, spaces: [space], currentSpace: space.id)
        let decoded = try JSONDecoder().decode(SessionStore.Session.self, from: JSONEncoder().encode(session))
        #expect(decoded.spaces?.first?.hasSeparateLogins == true)

        let legacy = ##"{"id": "\##(UUID().uuidString)", "name": "Home", "symbol": "house.fill", "color": "#5B4CF5"}"##
        #expect(try JSONDecoder().decode(Space.self, from: Data(legacy.utf8)).hasSeparateLogins == false)

        let (tabs, factory) = try makeStore()
        tabs.restore(decoded)
        let restored = try #require(tabs.tabs.first)
        #expect(restored.spaceID == space.id)
        #expect(factory.dataStore(forSpace: space.id) !== factory.dataStore)
        // The restored (active) tab loads on its space's own store, not the shared one.
        #expect(store(of: restored) === factory.dataStore(forSpace: space.id))
        await factory.removeSpaceData(space.id)
    }
}
