import Foundation

/// Size limits shared by the readers, so an odd or hostile file can't exhaust memory.
enum MigrationLimits {
    static let maxFileBytes = 100_000_000
    static let maxHistoryRows = 100_000
    static let maxBookmarks = 100_000
    static let maxTitle = 500

    static func read(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw SQLiteReader.Failure(reason: "\(url.lastPathComponent) is too large to import.") }
        return try Data(contentsOf: url)
    }

    static func title(_ text: String?) -> String {
        String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitle))
    }
}

// MARK: - Chromium (Chrome, Arc, Dia)

/// Chromium profiles: `Bookmarks` (JSON) and `History` (SQLite) in `Default`, `Profile 1`, ….
enum ChromiumReader {
    /// Throws when macOS refuses to list the folder (it protects some browsers' data), so that
    /// shows as a permission problem rather than "not found".
    static func profiles(in userData: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: userData.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: userData.path)
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted { ($0 == "Default" ? "" : $0) < ($1 == "Default" ? "" : $1) }
            .map { userData.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Bookmarks").path)
                || FileManager.default.fileExists(atPath: $0.appendingPathComponent("History").path) }
    }

    static func bookmarks(profile: URL) throws -> [ImportedBookmark] {
        let file = profile.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return parseBookmarks(try MigrationLimits.read(file))
    }

    /// `roots.bookmark_bar`, `roots.other` and `roots.synced`, walked recursively.
    static func parseBookmarks(_ data: Data) -> [ImportedBookmark] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String: Any] else { return [] }
        var out: [ImportedBookmark] = []
        func walk(_ node: [String: Any], _ folders: [String], depth: Int) {
            guard depth < 64, out.count < MigrationLimits.maxBookmarks else { return }
            if node["type"] as? String == "url" {
                if let raw = node["url"] as? String, let url = URL(string: raw), URLNormalizer.isImportable(url) {
                    out.append(ImportedBookmark(title: MigrationLimits.title(node["name"] as? String), url: url, folders: folders))
                }
                return
            }
            let name = MigrationLimits.title(node["name"] as? String)
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, folders + [name], depth: depth + 1) }
        }
        let names = [("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")]
        for (key, title) in names {
            guard let root = roots[key] as? [String: Any] else { continue }
            for child in root["children"] as? [[String: Any]] ?? [] { walk(child, [title], depth: 1) }
        }
        return out
    }

    static func history(profile: URL) throws -> [ImportedVisit] {
        let file = profile.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var out: [ImportedVisit] = []
        try SQLiteReader.read(file, query: """
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT \(MigrationLimits.maxHistoryRows)
            """) { row in
            guard let raw = row.string(0), let url = URL(string: raw), URLNormalizer.isImportable(url) else { return }
            out.append(ImportedVisit(url: url, title: MigrationLimits.title(row.string(1)), visitCount: Int(row.int(2)), lastVisit: date(webKitMicros: row.int(3))))
        }
        return out
    }

    static func historyCount(profile: URL) -> Int {
        let file = profile.appendingPathComponent("History")
        var count = 0
        try? SQLiteReader.read(file, query: "SELECT COUNT(*) FROM urls WHERE hidden = 0") { count = Int($0.int(0)) }
        return min(count, MigrationLimits.maxHistoryRows)
    }

    /// Chromium times are microseconds since 1601-01-01 UTC.
    static func date(webKitMicros value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
    }
}

// MARK: - Safari

/// `Bookmarks.plist` (binary property list) and `History.db` (SQLite) in `~/Library/Safari`.
enum SafariReader {
    static func bookmarks(in folder: URL) throws -> [ImportedBookmark] {
        let file = folder.appendingPathComponent("Bookmarks.plist")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return parseBookmarks(try MigrationLimits.read(file))
    }

    /// Walks `Children`, keeping `WebBookmarkTypeLeaf` entries and naming Safari's built-in lists.
    static func parseBookmarks(_ data: Data) -> [ImportedBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var out: [ImportedBookmark] = []
        let builtIn = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"]
        func walk(_ node: [String: Any], _ folders: [String], depth: Int) {
            guard depth < 64, out.count < MigrationLimits.maxBookmarks else { return }
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let raw = node["URLString"] as? String, let url = URL(string: raw), URLNormalizer.isImportable(url) else { return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                out.append(ImportedBookmark(title: MigrationLimits.title(title), url: url, folders: folders))
            case "WebBookmarkTypeList":
                let raw = node["Title"] as? String ?? ""
                let name = depth == 0 ? nil : (builtIn[raw] ?? MigrationLimits.title(raw))
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, folders + (name.map { [$0] } ?? []), depth: depth + 1) }
            default:
                return // proxies (History) and anything unknown
            }
        }
        walk(root, [], depth: 0)
        return out
    }

    static func history(in folder: URL) throws -> [ImportedVisit] {
        let file = folder.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var latest: [String: ImportedVisit] = [:]
        try SQLiteReader.read(file, query: """
            SELECT i.url, v.title, i.visit_count, v.visit_time FROM history_visits v
            JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC LIMIT \(MigrationLimits.maxHistoryRows * 3)
            """) { row in
            guard let raw = row.string(0), latest[raw] == nil, latest.count < MigrationLimits.maxHistoryRows,
                  let url = URL(string: raw), URLNormalizer.isImportable(url) else { return }
            latest[raw] = ImportedVisit(url: url, title: MigrationLimits.title(row.string(1)), visitCount: Int(row.int(2)),
                                        lastVisit: Date(timeIntervalSinceReferenceDate: row.double(3)))
        }
        return latest.values.sorted { $0.lastVisit > $1.lastVisit }
    }

    static func historyCount(in folder: URL) -> Int {
        var count = 0
        try? SQLiteReader.read(folder.appendingPathComponent("History.db"), query: "SELECT COUNT(*) FROM history_items") { count = Int($0.int(0)) }
        return min(count, MigrationLimits.maxHistoryRows)
    }
}

// MARK: - Firefox family (Zen)

/// `places.sqlite` in each profile under `Profiles/`.
enum FirefoxReader {
    static func profiles(in folder: URL) throws -> [URL] {
        let base = folder.appendingPathComponent("Profiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        return names.sorted().map { base.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
    }

    static func bookmarks(profile: URL) throws -> [ImportedBookmark] {
        struct Row { let id: Int64; let type: Int64; let parent: Int64; let title: String; let url: String?; let guid: String }
        var rows: [Row] = []
        try SQLiteReader.read(profile.appendingPathComponent("places.sqlite"), query: """
            SELECT b.id, b.type, b.parent, b.title, p.url, b.guid FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position LIMIT \(MigrationLimits.maxBookmarks * 2)
            """) { row in
            rows.append(Row(id: row.int(0), type: row.int(1), parent: row.int(2), title: MigrationLimits.title(row.string(3)),
                            url: row.string(4), guid: row.string(5) ?? ""))
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rootNames = ["toolbar_____": "Bookmarks Toolbar", "menu________": "Bookmarks Menu", "unfiled_____": "Other Bookmarks", "mobile______": "Mobile Bookmarks"]
        /// Folder names from the top, or nil inside tags (which aren't bookmarks).
        func folders(of parent: Int64) -> [String]? {
            var names: [String] = []
            var current = byID[parent]
            var depth = 0
            while let folder = current, depth < 64 {
                if folder.guid == "tags________" { return nil }
                if folder.guid == "root________" { break }
                names.insert(rootNames[folder.guid] ?? folder.title, at: 0)
                current = byID[folder.parent]
                depth += 1
            }
            return names
        }
        return rows.compactMap { row in
            guard row.type == 1, let raw = row.url, let url = URL(string: raw), URLNormalizer.isImportable(url), let path = folders(of: row.parent) else { return nil }
            return ImportedBookmark(title: row.title, url: url, folders: path)
        }
    }

    static func history(profile: URL) throws -> [ImportedVisit] {
        var out: [ImportedVisit] = []
        try SQLiteReader.read(profile.appendingPathComponent("places.sqlite"), query: """
            SELECT url, title, visit_count, last_visit_date FROM moz_places
            WHERE visit_count > 0 AND last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT \(MigrationLimits.maxHistoryRows)
            """) { row in
            guard let raw = row.string(0), let url = URL(string: raw), URLNormalizer.isImportable(url) else { return }
            out.append(ImportedVisit(url: url, title: MigrationLimits.title(row.string(1)), visitCount: Int(row.int(2)),
                                     lastVisit: Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000)))
        }
        return out
    }

    static func counts(profile: URL) -> (bookmarks: Int, history: Int) {
        var bookmarks = 0, history = 0
        let file = profile.appendingPathComponent("places.sqlite")
        try? SQLiteReader.read(file, query: "SELECT (SELECT COUNT(*) FROM moz_bookmarks WHERE type = 1), (SELECT COUNT(*) FROM moz_places WHERE visit_count > 0)") {
            bookmarks = Int($0.int(0)); history = Int($0.int(1))
        }
        return (min(bookmarks, MigrationLimits.maxBookmarks), min(history, MigrationLimits.maxHistoryRows))
    }
}

// MARK: - Arc sidebar

/// Arc's spaces and their pinned and unpinned tabs, from `StorableSidebar.json`. The format is
/// private, so it's read leniently: spaces list their containers, items reference their children,
/// and tabs carry `data.tab.savedURL`. Anything unrecognized is skipped.
enum ArcSidebarReader {
    static let maxTabs = 500

    static func spaces(in arcFolder: URL) throws -> [ImportedSpace] {
        let file = arcFolder.appendingPathComponent("StorableSidebar.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return parse(try MigrationLimits.read(file))
    }

    static func parse(_ data: Data) -> [ImportedSpace] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (object["sidebar"] as? [String: Any])?["containers"] as? [Any] else { return [] }
        var items: [String: [String: Any]] = [:]
        var spaces: [[String: Any]] = []
        for case let container as [String: Any] in containers {
            // Arrays alternate an id string and its object; only the objects matter.
            for case let item as [String: Any] in container["items"] as? [Any] ?? [] { if let id = item["id"] as? String { items[id] = item } }
            for case let space as [String: Any] in container["spaces"] as? [Any] ?? [] { spaces.append(space) }
        }
        var total = 0
        func tabs(under id: String, pinned: Bool, depth: Int) -> [ImportedSpace.Tab] {
            guard depth < 32, let item = items[id] else { return [] }
            var out: [ImportedSpace.Tab] = []
            if let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any], total < maxTabs,
               let raw = tab["savedURL"] as? String, let url = URL(string: raw), URLNormalizer.isImportable(url) {
                total += 1
                out.append(.init(title: MigrationLimits.title((item["title"] as? String) ?? (tab["savedTitle"] as? String)), url: url, pinned: pinned))
            }
            for child in item["childrenIds"] as? [String] ?? [] { out += tabs(under: child, pinned: pinned, depth: depth + 1) }
            return out
        }
        return spaces.compactMap { space in
            let labelled = space["containerIDs"] as? [Any] ?? []
            var found: [ImportedSpace.Tab] = []
            for (index, value) in labelled.enumerated() {
                guard let label = value as? String, label == "pinned" || label == "unpinned", index + 1 < labelled.count,
                      let container = labelled[index + 1] as? String else { continue }
                found += tabs(under: container, pinned: label == "pinned", depth: 0)
            }
            guard !found.isEmpty else { return nil }
            let title = MigrationLimits.title(space["title"] as? String)
            return ImportedSpace(name: title.isEmpty ? "Arc" : title, tabs: found)
        }
    }
}
