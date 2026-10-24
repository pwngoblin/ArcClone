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

    /// Shared CI runners are slower and noisier than a Mac, and run other suites alongside: time
    /// budgets get 3× headroom there (GitHub sets CI=true). Memory and web-view checks stay exact.
    static let slack: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3

    /// The fastest of `runs` timings: scheduling noise only ever adds time, so the minimum is the
    /// real cost and one unlucky pause can't fail the gate.
    static func best(_ runs: Int = 5, _ work: () -> Void) -> TimeInterval {
        (0..<runs).map { _ in
            let started = Date()
            work()
            return Date().timeIntervalSince(started)
        }.min() ?? 0
    }

    static func within(_ seconds: TimeInterval, _ budget: TimeInterval) -> Bool { seconds < budget * slack }

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
        #expect(Self.within(elapsed, 2.0))
    }

    @Test func searchingAndLookingUpFiveThousandTabsIsFast() throws {
        let store = try makeStore()
        fill(store)
        let ids = store.tabs.map(\.id)
        let sample = (0..<10_000).map { ids[($0 * 7_919) % ids.count] }
        let lookups = Self.best { for id in sample { _ = store.tab(id) } }

        let model = WindowModel(isPrivate: false, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
        let refresh = Self.best { model.refresh(from: store) }

        let bar = CommandBarModel(newTab: true, query: "topic 42", window: model)
        var suggestions: [CommandBarModel.Suggestion] = []
        let search = Self.best { suggestions = bar.suggestions }

        // Opening a tab creates its web view, so each run opens a different one.
        var next = Self.tabCount / 2
        let switchTime = Self.best(3) {
            store.activate(ids[next])
            model.refresh(from: store)
            next += 1
        }
        print("PERF 10k lookups \(ms(lookups)), sidebar refresh \(ms(refresh)), command bar search \(ms(search)), switch tab \(ms(switchTime))")
        #expect(suggestions.contains { if case .tab = $0 { true } else { false } })
        #expect(Self.within(lookups, 0.05))
        #expect(Self.within(refresh, 0.25))
        #expect(Self.within(search, 0.05))
        #expect(Self.within(switchTime, 0.25))
        #expect(store.active?.hasWebView == true) // the tab that was opened gets its web view
    }

    @Test func historyAndBookmarkSearchAtFullSize() {
        let history = History(directory: nil)
        let now = Date()
        history.importVisits((0..<History.maxEntries).map { (URL(string: "https://h\($0).example.com/a")!, "History page \($0)", now.addingTimeInterval(-Double($0))) })
        let bookmarks = Bookmarks(directory: nil)
        bookmarks.addFolder(.folder("Many", (0..<50_000).map { .link("Bookmark \($0)", URL(string: "https://b\($0).example.org/")!) }))
        // The first search after a change builds the search text once; typing then searches it.
        let historyCold = Self.best(1) { _ = history.search("page", limit: 12) }
        var visits: [History.Visit] = []
        let historySearch = Self.best { visits = history.search("page 1999", limit: 12) }
        let bookmarkCold = Self.best(1) { _ = bookmarks.search("bookmark", limit: 3) }
        var links: [Bookmarks.Node] = []
        let bookmarkSearch = Self.best { links = bookmarks.search("bookmark 4999", limit: 3) }
        print("PERF history (\(History.maxEntries)) first search \(ms(historyCold)), then \(ms(historySearch)); bookmarks (50k) first \(ms(bookmarkCold)), then \(ms(bookmarkSearch))")
        #expect(!visits.isEmpty && !links.isEmpty)
        #expect(Self.within(historySearch, 0.03) && Self.within(bookmarkSearch, 0.05))
        #expect(Self.within(historyCold, 0.25) && Self.within(bookmarkCold, 0.5))
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

/// Zero background wake-ups: the sleeper only schedules a wake-up when some tab could sleep.
@Suite(.serialized) @MainActor struct TabSleeperSchedulingTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func wakesOnlyWhenATabCouldSleep() throws {
        UserDefaults.standard.removeObject(forKey: Preferences.Key.sleepTabsAfter)
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        let store = TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
        let sleeper = TabSleeper(store: store)
        defer { sleeper.stop() }
        #expect(sleeper.nextCheck == nil) // no tabs: nothing scheduled

        let first = store.create(url: URL(string: "https://a.example/")!)
        sleeper.reschedule()
        #expect(sleeper.nextCheck == nil) // only the active tab: it never sleeps

        let started = Date()
        _ = store.create(url: URL(string: "https://b.example/")!) // becomes active; `first` is now in the background
        sleeper.reschedule()
        let threshold = try #require(TabSleeper.threshold)
        let due = try #require(sleeper.nextCheck)
        #expect(abs(due.timeIntervalSince(first.lastActivated.addingTimeInterval(threshold))) < 1)
        #expect(due.timeIntervalSince(started) > threshold - 5) // not a minute-by-minute poll

        first.sleep()
        sleeper.reschedule()
        #expect(sleeper.nextCheck == nil) // the only background tab is already asleep
    }
}
