import Darwin
import Foundation
import Testing
@testable import ArcCloneCore

/// The PR performance gate (CLAUDE.md): 5,000+ tabs must stay cheap in memory and fast to search.
/// Tabs that haven't been opened (restored or imported) must not cost a web view.
@Suite(.serialized) @MainActor struct TabManagerPerformanceTests {
    static let tabCount = 5_000
    /// Budget for each unopened tab, including its sidebar snapshot.
    static let maxBytesPerSleepingTab = 16 * 1024
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Physical memory charged to this process (what Activity Monitor shows as Memory).
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func makeStore() throws -> TabStore {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        return TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
    }

    func fill(_ store: TabStore) {
        let space = store.currentSpaceID
        for index in 0..<Self.tabCount {
            store.createAsleep(url: URL(string: "https://site\(index).example.com/page/\(index)")!, title: "Page \(index) about topic \(index % 97)",
                               pinned: false, in: space)
        }
    }

    @Test func fiveThousandUnopenedTabsAreCheap() throws {
        let store = try makeStore()
        _ = store.createAsleep(url: URL(string: "https://warmup.example/")!, title: "warm", pinned: false, in: store.currentSpaceID)
        let before = Self.footprint()
        let started = Date()
        fill(store)
        let model = WindowModel(isPrivate: false, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
        model.refresh(from: store)
        let elapsed = Date().timeIntervalSince(started)
        let perTab = (Self.footprint() - before) / Self.tabCount
        print("PERF \(Self.tabCount) unopened tabs: \(String(format: "%.2f", elapsed))s, \(perTab) bytes each, web views created: \(store.tabs.filter(\.hasWebView).count)")
        #expect(store.tabs.allSatisfy { !$0.hasWebView || $0.title == "warm" }, "unopened tabs must not create web views")
        #expect(perTab <= Self.maxBytesPerSleepingTab, "\(perTab) bytes per tab")
        #expect(elapsed < 2.0)
    }

    @Test func searchingAndLookingUpFiveThousandTabsIsFast() throws {
        let store = try makeStore()
        fill(store)
        let ids = store.tabs.map(\.id)
        var started = Date()
        for id in ids.shuffled().prefix(10_000) { _ = store.tab(id) }
        let lookups = Date().timeIntervalSince(started)

        let model = WindowModel(isPrivate: false, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
        started = Date()
        model.refresh(from: store)
        let refresh = Date().timeIntervalSince(started)

        started = Date()
        let bar = CommandBarModel(newTab: true, query: "topic 42", window: model)
        let suggestions = bar.suggestions
        let search = Date().timeIntervalSince(started)

        started = Date()
        store.activate(ids[Self.tabCount / 2])
        model.refresh(from: store)
        let switchTime = Date().timeIntervalSince(started)
        print("PERF 10k lookups \(ms(lookups)), sidebar refresh \(ms(refresh)), command bar search \(ms(search)), switch tab \(ms(switchTime))")
        #expect(suggestions.contains { if case .tab = $0 { true } else { false } })
        #expect(lookups < 0.05)
        #expect(refresh < 0.25)
        #expect(search < 0.05)
        #expect(switchTime < 0.25)
        #expect(store.active?.hasWebView == true) // the tab that was opened gets its web view
    }

    @Test func historyAndBookmarkSearchAtFullSize() {
        let history = History(directory: nil)
        let now = Date()
        history.importVisits((0..<History.maxEntries).map { (URL(string: "https://h\($0).example.com/a")!, "History page \($0)", now.addingTimeInterval(-Double($0))) })
        let bookmarks = Bookmarks(directory: nil)
        bookmarks.addFolder(.folder("Many", (0..<50_000).map { .link("Bookmark \($0)", URL(string: "https://b\($0).example.org/")!) }))
        // The first search after a change builds the search text once; typing then searches it.
        var started = Date()
        _ = history.search("page", limit: 12)
        let historyCold = Date().timeIntervalSince(started)
        started = Date()
        let visits = history.search("page 1999", limit: 12)
        let historySearch = Date().timeIntervalSince(started)
        started = Date()
        _ = bookmarks.search("bookmark", limit: 3)
        let bookmarkCold = Date().timeIntervalSince(started)
        started = Date()
        let links = bookmarks.search("bookmark 4999", limit: 3)
        let bookmarkSearch = Date().timeIntervalSince(started)
        print("PERF history (\(History.maxEntries)) first search \(ms(historyCold)), then \(ms(historySearch)); bookmarks (50k) first \(ms(bookmarkCold)), then \(ms(bookmarkSearch))")
        #expect(!visits.isEmpty && !links.isEmpty)
        #expect(historySearch < 0.03 && bookmarkSearch < 0.05)
        #expect(historyCold < 0.25 && bookmarkCold < 0.5)
    }

    private func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }
}

@Suite @MainActor struct TabVirtualizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func makeStore() throws -> TabStore {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        return TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
    }

    @Test func sleepingReleasesTheWebViewAndWakingBringsItBack() throws {
        let store = try makeStore()
        let tab = store.create(url: URL(string: "https://example.com/")!)
        #expect(tab.hasWebView)
        tab.sleep()
        #expect(tab.isSleeping && !tab.hasWebView)
        #expect(tab.url?.host == "example.com") // still knows where it was
        tab.wake()
        #expect(!tab.isSleeping && tab.hasWebView)
    }

    @Test func restoredSessionsOnlyLoadTheActiveTab() throws {
        let store = try makeStore()
        let entries = (0..<20).map { SessionStore.Session.Entry(url: URL(string: "https://s\($0).example/")!, title: "Saved \($0)", pinned: false, bookmark: nil, space: nil) }
        store.restore(SessionStore.Session(tabs: entries, activeIndex: 3, spaces: nil, currentSpace: nil))
        #expect(store.tabs.count == 20 && store.activeID == store.tabs[3].id)
        #expect(store.tabs.filter(\.hasWebView).map(\.id) == [store.tabs[3].id])
        #expect(store.tabs[7].title == "Saved 7" && store.tabs[7].isSleeping)
    }
}
