import Foundation
import SQLite3
import Testing
@testable import ArcCloneCore

/// Builds fake browser profiles on disk, as the real browsers lay them out.
private struct FakeLibrary {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-migration-test-\(UUID().uuidString)", isDirectory: true)
    var appSupport: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    var safari: URL { home.appendingPathComponent("Library/Safari", isDirectory: true) }

    func write(_ text: String, to relative: String, in base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Creates a SQLite database by running `sql`. `keepOpen` leaves the connection open so recent
    /// writes stay in the -wal file, like a running browser.
    @discardableResult
    func sqlite(_ relative: String, in base: URL, _ sql: String, wal: Bool = false, keepOpen: Bool = false) throws -> OpaquePointer? {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteReader.Failure(reason: "open") }
        if wal { sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteReader.Failure(reason: String(cString: sqlite3_errmsg(db))) }
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private let chromeBookmarks = #"""
{"roots": {
  "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
    {"type": "url", "name": "Swift", "url": "https://swift.org/?utm_source=x"},
    {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"},
    {"type": "folder", "name": "Work", "children": [{"type": "url", "name": "Docs", "url": "https://docs.example.com/guide/"}]}]},
  "other": {"type": "folder", "children": [{"type": "url", "name": "News", "url": "https://news.example.com/"}]},
  "synced": {"type": "folder", "children": []}}}
"""#

private func chromeHistorySQL(_ rows: [(String, String, Int, Date)]) -> String {
    let values = rows.map { url, title, count, date in
        "('\(url)', '\(title)', \(count), \(Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)), 0)"
    }.joined(separator: ",")
    return "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER); INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES \(values);"
}

@Suite struct URLNormalizerTests {
    @Test func cleansTrackingAndCase() {
        #expect(URLNormalizer.clean(URL(string: "HTTPS://Example.COM:443/Path/?utm_source=a&id=7&fbclid=x")!)?.absoluteString == "https://example.com/Path?id=7")
        #expect(URLNormalizer.clean(URL(string: "https://example.com")!)?.absoluteString == "https://example.com/")
        #expect(URLNormalizer.key(URL(string: "https://example.com/a/#top")!) == URLNormalizer.key(URL(string: "https://EXAMPLE.com/a?utm_medium=b")!))
    }

    @Test func onlyWebPagesAreImported() {
        for bad in ["javascript:alert(1)", "file:///etc/hosts", "chrome://settings", "data:text/html,x", "about:blank"] {
            #expect(!URLNormalizer.isImportable(URL(string: bad)!), "\(bad)")
        }
        #expect(URLNormalizer.isImportable(URL(string: "http://example.com/x")!))
    }
}

@Suite struct BrowserReaderTests {
    @Test func chromiumBookmarksKeepFoldersAndDropBookmarklets() {
        let bookmarks = ChromiumReader.parseBookmarks(Data(chromeBookmarks.utf8))
        #expect(bookmarks.map(\.title) == ["Swift", "Docs", "News"])
        #expect(bookmarks[1].folders == ["Bookmarks Bar", "Work"] && bookmarks[2].folders == ["Other Bookmarks"])
    }

    @Test func safariBookmarksFromABinaryPlist() throws {
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com/", "URIDictionary": ["title": "Apple"]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Reading", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://webkit.org/blog", "URIDictionary": ["title": "WebKit"]]]]]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "javascript:void(0)", "URIDictionary": ["title": "x"]]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let bookmarks = SafariReader.parseBookmarks(data)
        #expect(bookmarks.map(\.title) == ["Apple", "WebKit"])
        #expect(bookmarks[1].folders == ["Favorites", "Reading"])
    }

    @Test func arcSidebarSpacesAndTabs() {
        let json = #"""
        {"sidebar": {"containers": [{"global": {}}, {
          "spaces": ["s1", {"id": "s1", "title": "Work", "containerIDs": ["pinned", "p1", "unpinned", "u1"]}],
          "items": [
            "p1", {"id": "p1", "childrenIds": ["t1", "f1"], "data": {"itemContainer": {}}},
            "t1", {"id": "t1", "title": "Mail", "childrenIds": [], "data": {"tab": {"savedURL": "https://mail.example.com/", "savedTitle": "Inbox"}}},
            "f1", {"id": "f1", "title": "Folder", "childrenIds": ["t2"], "data": {"list": {}}},
            "t2", {"id": "t2", "title": null, "childrenIds": [], "data": {"tab": {"savedURL": "https://calendar.example.com/", "savedTitle": "Calendar"}}},
            "u1", {"id": "u1", "childrenIds": ["t3"], "data": {"itemContainer": {}}},
            "t3", {"id": "t3", "childrenIds": [], "data": {"tab": {"savedURL": "javascript:x", "savedTitle": "bad"}}}
          ]}]}}
        """#
        let spaces = ArcSidebarReader.parse(Data(json.utf8))
        #expect(spaces.count == 1 && spaces[0].name == "Work")
        #expect(spaces[0].tabs.map(\.title) == ["Mail", "Calendar"] && spaces[0].tabs.allSatisfy(\.pinned))
        #expect(ArcSidebarReader.parse(Data("{\"unexpected\": true}".utf8)).isEmpty)
    }

    /// A running browser keeps recent visits in the -wal file; the private copy must include them.
    @Test func sqliteCopiesIncludeTheWriteAheadLog() throws {
        let fake = FakeLibrary()
        defer { fake.remove() }
        let db = try fake.sqlite("History", in: fake.home, chromeHistorySQL([("https://a.example/", "A", 3, Date())]), wal: true, keepOpen: true)
        defer { sqlite3_close(db) }
        #expect(FileManager.default.fileExists(atPath: fake.home.appendingPathComponent("History-wal").path))
        var urls: [String] = []
        try SQLiteReader.read(fake.home.appendingPathComponent("History"), query: "SELECT url FROM urls") { urls.append($0.string(0) ?? "") }
        #expect(urls == ["https://a.example/"])
        // The original is untouched: no stray files from our read.
        let names = try FileManager.default.contentsOfDirectory(atPath: fake.home.path).sorted()
        #expect(names.allSatisfy { $0.hasPrefix("History") })
    }
}

@Suite struct MigrationEngineTests {
    /// Every supported browser, from fake profiles to merged results.
    @Test func scansAndReadsAllFiveBrowsers() async throws {
        let fake = FakeLibrary()
        defer { fake.remove() }
        let now = Date()
        let old = now.addingTimeInterval(-86_400 * 3)
        // Chrome, two profiles.
        try fake.write(chromeBookmarks, to: "Google/Chrome/Default/Bookmarks", in: fake.appSupport)
        try fake.sqlite("Google/Chrome/Default/History", in: fake.appSupport,
                        chromeHistorySQL([("https://swift.org/", "Swift", 10, old), ("https://shared.example/", "Shared (old)", 2, old)]))
        try fake.write(#"{"roots": {"bookmark_bar": {"children": [{"type": "url", "name": "P2", "url": "https://profile2.example/"}]}}}"#,
                       to: "Google/Chrome/Profile 1/Bookmarks", in: fake.appSupport)
        // Arc: Chromium data under "User Data", sidebar beside it.
        try fake.sqlite("Arc/User Data/Default/History", in: fake.appSupport,
                        chromeHistorySQL([("https://shared.example/?utm_campaign=z", "Shared", 7, now)]))
        try fake.write(#"{"sidebar": {"containers": [{"spaces": [{"id": "s", "title": "Home", "containerIDs": ["unpinned", "u"]}], "items": [{"id": "u", "childrenIds": ["t"]}, {"id": "t", "title": "Tab", "data": {"tab": {"savedURL": "https://tab.example/"}}}]}]}}"#,
                       to: "Arc/StorableSidebar.json", in: fake.appSupport)
        // Dia: bookmarks only.
        try fake.write(#"{"roots": {"other": {"children": [{"type": "url", "name": "Swift again", "url": "https://swift.org"}]}}}"#,
                       to: "Dia/User Data/Default/Bookmarks", in: fake.appSupport)
        // Zen (Firefox places).
        let mozMicros = Int64(now.timeIntervalSince1970 * 1_000_000)
        try fake.sqlite("zen/Profiles/abc.Default (release)/places.sqlite", in: fake.appSupport, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, title TEXT, position INTEGER, guid TEXT);
            INSERT INTO moz_places VALUES (1, 'https://zen-browser.app/', 'Zen', 4, \(mozMicros)), (2, 'https://tagged.example/', 'Tagged', 1, \(mozMicros));
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, '', 0, 'root________'), (3, 2, NULL, 1, 'toolbar', 0, 'toolbar_____'),
              (4, 2, NULL, 1, 'tags', 1, 'tags________'), (10, 1, 1, 3, 'Zen Home', 0, 'aaaaaaaaaaaa'), (11, 2, NULL, 4, 'mytag', 0, 'bbbbbbbbbbbb'),
              (12, 1, 2, 11, 'Tagged', 0, 'cccccccccccc');
            """)
        // Safari.
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://news.example.com", "URIDictionary": ["title": "News (Safari)"]]]]]]
        try FileManager.default.createDirectory(at: fake.safari, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: fake.safari.appendingPathComponent("Bookmarks.plist"))
        try fake.sqlite("History.db", in: fake.safari, """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            INSERT INTO history_items VALUES (1, 'https://apple.com/', 5);
            INSERT INTO history_visits VALUES (1, 1, \(old.timeIntervalSinceReferenceDate), 'Apple (old)'), (2, 1, \(now.timeIntervalSinceReferenceDate), 'Apple');
            """)

        let roots: [MigrationRoot: URL] = [.applicationSupport: fake.appSupport, .safari: fake.safari]
        var scans: [SourceBrowser: BrowserScan] = [:]
        for browser in SourceBrowser.allCases {
            let folder = try #require(MigrationEngine.locate(browser, in: roots), "\(browser)")
            scans[browser] = try await MigrationEngine.scan(browser, folder: folder)
        }
        #expect(scans[.chrome] == BrowserScan(bookmarks: 4, history: 2, spaces: 0))
        #expect(scans[.arc] == BrowserScan(bookmarks: 0, history: 1, spaces: 1))
        #expect(scans[.dia] == BrowserScan(bookmarks: 1, history: 0, spaces: 0))
        #expect(scans[.zen]?.bookmarks == 2 && scans[.zen]?.history == 2)
        #expect(scans[.safari] == BrowserScan(bookmarks: 1, history: 1, spaces: 0))

        func folder(_ b: SourceBrowser) -> URL { MigrationEngine.locate(b, in: roots)! }
        let zenBookmarks = try await MigrationEngine.readBookmarks(.zen, folder: folder(.zen))
        #expect(zenBookmarks.map(\.title) == ["Zen Home"] && zenBookmarks[0].folders == ["Bookmarks Toolbar"]) // tags aren't bookmarks
        let safariHistory = try await MigrationEngine.readHistory(.safari, folder: folder(.safari))
        #expect(safariHistory.count == 1 && safariHistory[0].title == "Apple") // latest visit's title

        // Merge across browsers.
        var bookmarkSources: [(SourceBrowser, [ImportedBookmark])] = []
        var historySources: [[ImportedVisit]] = []
        for browser in [SourceBrowser.chrome, .arc, .dia, .zen, .safari] {
            bookmarkSources.append((browser, try await MigrationEngine.readBookmarks(browser, folder: folder(browser))))
            historySources.append(try await MigrationEngine.readHistory(browser, folder: folder(browser)))
        }
        let folders = MigrationMerger.bookmarkFolders(bookmarkSources)
        #expect(folders.map(\.title) == ["Imported from Google Chrome", "Imported from Zen"]) // Dia's and Safari's only links were duplicates
        let history = MigrationMerger.mergeHistory(historySources)
        let shared = try #require(history.first { $0.url.host == "shared.example" })
        #expect(shared.visitCount == 7 && shared.title == "Shared" && shared.url.query == nil) // highest count, latest title, tracking removed
        #expect(Set(history.map { $0.url.absoluteString }).count == history.count)
        let spaces = try await MigrationEngine.readSpaces(.arc, folder: folder(.arc))
        #expect(spaces.first?.tabs.first?.url.absoluteString == "https://tab.example/")
    }
}

@Suite struct MigrationLocateTests {
    /// Whatever level the user grants in the folder picker, the browser is found.
    @Test func findsBrowsersFromAnyReasonableGrant() throws {
        let fake = FakeLibrary()
        defer { fake.remove() }
        try fake.write("{}", to: "Dia/User Data/Local State", in: fake.appSupport)
        try fake.write("{}", to: "Google/Chrome/Default/Bookmarks", in: fake.appSupport)
        try FileManager.default.createDirectory(at: fake.safari, withIntermediateDirectories: true)
        try Data().write(to: fake.safari.appendingPathComponent("Bookmarks.plist"))
        let dia = fake.appSupport.appendingPathComponent("Dia")
        let library = fake.home.appendingPathComponent("Library")
        for grant in [fake.appSupport, dia, dia.appendingPathComponent("User Data"), library, fake.home] {
            #expect(MigrationEngine.locate(.dia, in: [.applicationSupport: grant])?.standardizedFileURL == dia.standardizedFileURL, "\(grant.path)")
        }
        #expect(MigrationEngine.locate(.chrome, in: [.applicationSupport: library]) != nil)
        #expect(MigrationEngine.locate(.safari, in: [.applicationSupport: library]) != nil) // ~/Library covers Safari too
        #expect(MigrationEngine.locate(.chrome, in: [.applicationSupport: dia]) == nil)   // Dia's folder doesn't hold Chrome
        // A same-named folder without browser data isn't mistaken for the browser.
        try FileManager.default.createDirectory(at: fake.appSupport.appendingPathComponent("zen"), withIntermediateDirectories: true)
        #expect(MigrationEngine.locate(.zen, in: [.applicationSupport: fake.appSupport]) == nil)
    }
}

@Suite struct MigrationPermissionTests {
    /// A protected browser folder shows as a permission problem with guidance, not as "not found".
    @Test func protectedFoldersExplainThemselves() async throws {
        let fake = FakeLibrary()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.appSupport.appendingPathComponent("Google/Chrome").path)
            fake.remove()
        }
        try fake.write(chromeBookmarks, to: "Google/Chrome/Default/Bookmarks", in: fake.appSupport)
        let chrome = fake.appSupport.appendingPathComponent("Google/Chrome")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: chrome.path)
        do {
            _ = try await MigrationEngine.scan(.chrome, folder: chrome)
            Issue.record("expected a permission error")
        } catch {
            let message = await MainActor.run { MigrationModel.explain(error, browser: .chrome) }
            #expect(message.contains("Full Disk Access") && message.contains("Google Chrome"), "\(message)")
        }
    }
}

@Suite @MainActor struct ImportDestinationTests {
    @Test func bookmarksSkipDuplicatesAndNonWebLinks() {
        let store = Bookmarks(directory: nil)
        let first = store.addFolder(.folder("Imported from Chrome", [.link("Swift", URL(string: "https://swift.org/")!),
                                                                    .folder("Work", [.link("Bad", URL(string: "javascript:x")!)])]))
        #expect(first == 1 && store.root.count == 1 && store.root[0].children?.count == 1) // the empty folder is dropped
        #expect(store.addFolder(.folder("Imported from Arc", [.link("Swift", URL(string: "https://SWIFT.org/?utm_source=a")!)])) == 0)
        #expect(store.search("swi").map(\.title) == ["Swift"])
    }

    @Test func historyImportKeepsTheNewerVisit() {
        let history = History(directory: nil)
        let url = URL(string: "https://example.com/")!
        history.record(url: url, title: "Here")
        let older = Date().addingTimeInterval(-3_600)
        #expect(history.importVisits([(url, "Imported", older), (URL(string: "https://new.example/")!, "New", older)]) == 1)
        #expect(history.visits.first { $0.url == url }?.title == "Here")
        #expect(history.visits.count == 2)
    }
}
