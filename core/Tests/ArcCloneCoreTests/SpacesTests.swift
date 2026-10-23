import Foundation
import Testing
@testable import ArcCloneCore

@Suite @MainActor struct SpacesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func makeStore() throws -> TabStore {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        return TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
    }

    @Test func spacesKeepTheirOwnTabsAndActiveTab() throws {
        let store = try makeStore()
        let home = store.currentSpaceID
        let a = store.create(url: nil)
        let b = store.create(url: nil)
        store.activate(a.id)
        let work = store.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF")
        #expect(store.currentSpaceID == work.id && store.visibleTabs.isEmpty && store.activeID == nil)
        let c = store.create(url: nil)
        #expect(store.visibleTabs.map(\.id) == [c.id])
        store.switchSpace(to: home)
        #expect(store.activeID == a.id && Set(store.visibleTabs.map(\.id)) == [a.id, b.id])
        store.switchSpace(by: 1)
        #expect(store.currentSpaceID == work.id && store.activeID == c.id)
    }

    @Test func activatingATabInAnotherSpaceSwitchesToIt() throws {
        let store = try makeStore()
        let a = store.create(url: nil)
        store.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF")
        store.activate(a.id)
        #expect(store.currentSpaceID == a.spaceID && store.activeID == a.id)
    }

    @Test func movingAndDeletingSpaces() throws {
        let store = try makeStore()
        let home = store.currentSpaceID
        let a = store.create(url: nil)
        let work = store.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF")
        let b = store.create(url: nil)
        store.moveTab(b.id, toSpace: home)
        #expect(store.tab(b.id)?.spaceID == home && store.visibleTabs.isEmpty)
        let c = store.create(url: nil)
        store.deleteSpace(work.id)
        #expect(store.spaces.count == 1 && store.tab(c.id) == nil && store.tab(a.id) != nil)
        store.deleteSpace(home) // the last space stays
        #expect(store.spaces.count == 1)
    }

    @Test func sessionsRoundTripSpaces() throws {
        let store = try makeStore()
        store.create(url: URL(string: "https://home.example")!)
        let work = store.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF")
        store.create(url: URL(string: "https://work.example")!)
        let data = try JSONEncoder().encode(store.session)
        let restored = try makeStore()
        restored.restore(try JSONDecoder().decode(SessionStore.Session.self, from: data))
        #expect(restored.spaces.map(\.name) == ["Personal", "Work"])
        #expect(restored.currentSpaceID == work.id)
        #expect(restored.visibleTabs.map(\.url?.host) == ["work.example"])
        #expect(restored.tabs.count == 2)
    }
}
