import AppKit
import Foundation
import Testing
@testable import ArcCloneCore

@Suite @MainActor struct HistoryTests {
    func makeHistory(at dir: URL? = nil, keys: KeyStore = InMemoryKeyStore(), now: Date = Date()) -> History {
        let history = History(directory: dir, keys: keys)
        history.now = { now }
        return history
    }

    @Test func recordsWebPagesMostRecentFirst() {
        let history = makeHistory()
        history.record(url: URL(string: "https://a.example")!, title: "A")
        history.record(url: URL(string: "https://b.example")!, title: "B")
        history.record(url: URL(string: "file:///etc/hosts")!, title: "local")
        history.record(url: URL(string: "about:blank")!, title: nil)
        #expect(history.visits.map(\.title) == ["B", "A"])
    }

    @Test func revisitsWithinHalfAnHourCoalesce() {
        var clock = Date()
        let history = makeHistory()
        history.now = { clock }
        let url = URL(string: "https://a.example/page")!
        history.record(url: url, title: "Old")
        clock += 600
        history.record(url: url, title: "New")
        #expect(history.visits.count == 1 && history.visits[0].title == "New")
        clock += 3600
        history.record(url: url, title: "Later")
        #expect(history.visits.count == 2)
    }

    @Test func searchMatchesTitleAndURLAndDedupes() {
        var clock = Date()
        let history = makeHistory()
        history.now = { clock }
        history.record(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog")
        clock += 7200
        history.record(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog")
        history.record(url: URL(string: "https://news.example")!, title: "News")
        #expect(history.search("swift").count == 1)
        #expect(history.search("NEWS").map(\.title) == ["News"])
        #expect(history.recent(10).count == 2)
    }

    @Test func clearByRangeAndRemoveByID() {
        let base = Date()
        var clock = base.addingTimeInterval(-7200)
        let history = makeHistory()
        history.now = { clock }
        history.record(url: URL(string: "https://old.example")!, title: "Old")
        clock = base
        history.record(url: URL(string: "https://new.example")!, title: "New")
        history.clear(since: base.addingTimeInterval(-3600))
        #expect(history.visits.map(\.title) == ["Old"])
        history.remove([history.visits[0].id])
        #expect(history.visits.isEmpty)
    }

    @Test func retentionDropsOldVisits() {
        UserDefaults.standard.set(1, forKey: Preferences.Key.historyRetentionDays)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.Key.historyRetentionDays) }
        var clock = Date().addingTimeInterval(-3 * 86_400)
        let history = makeHistory()
        history.now = { clock }
        history.record(url: URL(string: "https://ancient.example")!, title: "Ancient")
        clock = Date()
        history.record(url: URL(string: "https://fresh.example")!, title: "Fresh")
        #expect(history.visits.map(\.title) == ["Fresh"])
    }

    @Test func persistsEncryptedAndReloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = InMemoryKeyStore()
        let history = makeHistory(at: dir, keys: keys)
        history.record(url: URL(string: "https://bank.example/statement?id=42")!, title: "Statement")
        await history.flush()
        let raw = try Data(contentsOf: dir.appendingPathComponent("history.sealed"))
        #expect(raw.range(of: Data("bank.example".utf8)) == nil)

        let reloaded = makeHistory(at: dir, keys: keys)
        await reloaded.load()
        #expect(reloaded.visits.map(\.title) == ["Statement"])

        reloaded.clear()
        await reloaded.flush()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.sealed").path))
    }
}

@Suite @MainActor struct HistoryMenuTests {
    @Test func historyMenuListsRecentlyVisitedPages() {
        let history = History(directory: nil, keys: InMemoryKeyStore())
        history.record(url: URL(string: "https://a.example/")!, title: "Alpha")
        history.record(url: URL(string: "https://b.example/")!, title: "")
        let delegate = HistoryMenuDelegate()
        delegate.history = history
        let menu = NSMenu(title: "History")
        menu.addItem(NSMenuItem(title: "Back", action: nil, keyEquivalent: "["))
        delegate.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Recently Visited"))
        #expect(titles.contains("Alpha") && titles.contains("b.example"))
        #expect((menu.items.first { $0.title == "Alpha" }?.representedObject as? URL)?.host == "a.example")
        // Opening the menu again replaces, rather than duplicates, the list.
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.filter { $0.title == "Alpha" }.count == 1)
    }
}

@Suite struct HistoryFilterTests {
    let calendar = Calendar.current
    let now = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!

    func visit(_ host: String, daysAgo: Int) -> History.Visit {
        .init(id: UUID(), url: URL(string: "https://\(host)/p")!, title: host, visitedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
    }

    @Test func timeRangesSplitVisitsCorrectly() {
        let today = visit("a.example", daysAgo: 0), yesterday = visit("b.example", daysAgo: 1)
        let fiveDays = visit("c.example", daysAgo: 5), twentyDays = visit("d.example", daysAgo: 20), ancient = visit("e.example", daysAgo: 60)
        let all = [today, yesterday, fiveDays, twentyDays, ancient]
        func hosts(_ f: HistoryFilter) -> [String] { all.filter { f.matches($0, now: now) }.map(\.title) }
        #expect(hosts(.today) == ["a.example"])
        #expect(hosts(.yesterday) == ["b.example"])
        #expect(hosts(.week) == ["a.example", "b.example", "c.example"])
        #expect(hosts(.month) == ["a.example", "b.example", "c.example", "d.example"])
        #expect(hosts(.older) == ["e.example"])
        #expect(hosts(.all).count == 5)
    }

    @Test func mostVisitedGroupsWWWAndSortsByCount() {
        let visits = [visit("www.news.example", daysAgo: 0), visit("news.example", daysAgo: 1), visit("blog.example", daysAgo: 2)]
        let top = HistoryFilter.topSites(visits)
        #expect(top.first?.host == "news.example" && top.first?.count == 2)
        #expect(HistoryFilter.site("news.example").matches(visits[0], now: now))
    }
}
