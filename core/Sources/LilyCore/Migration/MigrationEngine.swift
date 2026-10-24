import Foundation

/// Where every migration file read and SQLite query runs: off the main thread, one at a time.
@globalActor
actor MigrationActor {
    static let shared = MigrationActor()
}

/// Finds and reads other browsers' data inside folders the user granted.
enum MigrationEngine {
    /// The browser's own folder inside the granted folders, if it's there. People grant different
    /// levels in the folder picker, so any of these work: `Application Support` (expected), the
    /// browser's own folder, `~/Library`, or the home folder. Safari likewise accepts `~/Library`.
    static func locate(_ browser: SourceBrowser, in granted: [MigrationRoot: URL]) -> URL? {
        candidates(browser, in: granted).first { isDirectory($0) && looksLikeData(browser, $0) }
    }

    static func candidates(_ browser: SourceBrowser, in granted: [MigrationRoot: URL]) -> [URL] {
        let relative = browser == .safari ? "Safari" : browser.relativePath
        var out: [URL] = []
        for root in Set(granted.values) {
            out.append(root.appendingPathComponent(relative, isDirectory: true))                      // Application Support / ~/Library (Safari)
            out.append(root.appendingPathComponent("Application Support/\(relative)", isDirectory: true)) // ~/Library
            out.append(root.appendingPathComponent("Library/Application Support/\(relative)", isDirectory: true)) // home
            if browser == .safari { out.append(root.appendingPathComponent("Library/Safari", isDirectory: true)) }
            // The browser's folder itself (or its "User Data").
            let parts = relative.split(separator: "/").map(String.init)
            if root.path.hasSuffix("/" + relative) || (parts.count == 1 && root.lastPathComponent == relative) { out.append(root) }
            if root.lastPathComponent == "User Data", root.deletingLastPathComponent().path.hasSuffix("/" + relative) { out.append(root.deletingLastPathComponent()) }
            if browser == .safari, root.lastPathComponent == "Safari" { out.append(root) }
        }
        return out
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Guards against a same-named folder that isn't the browser's (e.g. "zen" from another app).
    private static func looksLikeData(_ browser: SourceBrowser, _ folder: URL) -> Bool {
        let fm = FileManager.default
        switch browser.engine {
        case .chromium:
            let userData = browser.userDataPath.isEmpty ? folder : folder.appendingPathComponent(browser.userDataPath)
            return fm.fileExists(atPath: userData.appendingPathComponent("Default").path) || fm.fileExists(atPath: userData.appendingPathComponent("Local State").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("StorableSidebar.json").path)
        case .safari:
            return fm.fileExists(atPath: folder.appendingPathComponent("Bookmarks.plist").path) || fm.fileExists(atPath: folder.appendingPathComponent("History.db").path)
        case .firefox:
            return fm.fileExists(atPath: folder.appendingPathComponent("Profiles").path) || fm.fileExists(atPath: folder.appendingPathComponent("profiles.ini").path)
        }
    }

    /// Counts what's there, for the browser cards.
    @MigrationActor
    static func scan(_ browser: SourceBrowser, folder: URL) throws -> BrowserScan {
        switch browser.engine {
        case .chromium:
            let userData = browser.userDataPath.isEmpty ? folder : folder.appendingPathComponent(browser.userDataPath, isDirectory: true)
            let profiles = try ChromiumReader.profiles(in: userData)
            let bookmarks = try profiles.reduce(0) { $0 + (try ChromiumReader.bookmarks(profile: $1)).count }
            let history = try profiles.reduce(0) { $0 + (try ChromiumReader.historyCount(profile: $1)) }
            let spaces = browser.supportsSpaces ? (try? ArcSidebarReader.spaces(in: folder))?.count ?? 0 : 0
            return BrowserScan(bookmarks: bookmarks, history: history, spaces: spaces)
        case .safari:
            return BrowserScan(bookmarks: try SafariReader.bookmarks(in: folder).count, history: try SafariReader.historyCount(in: folder), spaces: 0)
        case .firefox:
            let counts = try FirefoxReader.profiles(in: folder).map { try FirefoxReader.counts(profile: $0) }
            return BrowserScan(bookmarks: counts.reduce(0) { $0 + $1.bookmarks }, history: counts.reduce(0) { $0 + $1.history }, spaces: 0)
        }
    }

    @MigrationActor
    static func readBookmarks(_ browser: SourceBrowser, folder: URL) throws -> [ImportedBookmark] {
        switch browser.engine {
        case .chromium: return try chromiumProfiles(browser, folder).flatMap { try ChromiumReader.bookmarks(profile: $0) }
        case .safari: return try SafariReader.bookmarks(in: folder)
        case .firefox: return try FirefoxReader.profiles(in: folder).flatMap { try FirefoxReader.bookmarks(profile: $0) }
        }
    }

    @MigrationActor
    static func readHistory(_ browser: SourceBrowser, folder: URL) throws -> [ImportedVisit] {
        switch browser.engine {
        case .chromium: return try chromiumProfiles(browser, folder).flatMap { try ChromiumReader.history(profile: $0) }
        case .safari: return try SafariReader.history(in: folder)
        case .firefox: return try FirefoxReader.profiles(in: folder).flatMap { try FirefoxReader.history(profile: $0) }
        }
    }

    @MigrationActor
    static func readSpaces(_ browser: SourceBrowser, folder: URL) throws -> [ImportedSpace] {
        browser.supportsSpaces ? try ArcSidebarReader.spaces(in: folder) : []
    }

    private static func chromiumProfiles(_ browser: SourceBrowser, _ folder: URL) throws -> [URL] {
        try ChromiumReader.profiles(in: browser.userDataPath.isEmpty ? folder : folder.appendingPathComponent(browser.userDataPath, isDirectory: true))
    }
}

/// Combines what several browsers had, de-duplicated by normalized address.
enum MigrationMerger {
    /// One visit per page across all sources: the highest visit count, the latest visit, and the
    /// title from the latest visit that has one. Addresses are cleaned of tracking parameters.
    static func mergeHistory(_ sources: [[ImportedVisit]]) -> [ImportedVisit] {
        var merged: [String: ImportedVisit] = [:]
        for visit in sources.joined() {
            guard let clean = URLNormalizer.clean(visit.url) else { continue }
            let key = URLNormalizer.key(clean)
            if var existing = merged[key] {
                existing.visitCount = max(existing.visitCount, visit.visitCount)
                if visit.lastVisit > existing.lastVisit {
                    existing.lastVisit = visit.lastVisit
                    if !visit.title.isEmpty { existing.title = visit.title }
                } else if existing.title.isEmpty {
                    existing.title = visit.title
                }
                merged[key] = existing
            } else {
                merged[key] = ImportedVisit(url: clean, title: visit.title, visitCount: visit.visitCount, lastVisit: visit.lastVisit)
            }
        }
        return merged.values.sorted { $0.lastVisit > $1.lastVisit }
    }

    /// Bookmarks as one folder per browser ("Imported from Chrome"), keeping each browser's
    /// folders. A page bookmarked in several browsers is kept once, in the first browser listed.
    static func bookmarkFolders(_ sources: [(SourceBrowser, [ImportedBookmark])]) -> [Bookmarks.Node] {
        var seen = Set<String>()
        var folders: [Bookmarks.Node] = []
        for (browser, bookmarks) in sources {
            var tree: [Bookmarks.Node] = []
            for bookmark in bookmarks {
                guard let clean = URLNormalizer.clean(bookmark.url), seen.insert(URLNormalizer.key(clean)).inserted else { continue }
                insert(.link(bookmark.title.isEmpty ? (clean.host ?? clean.absoluteString) : bookmark.title, clean), path: bookmark.folders, into: &tree)
            }
            if !tree.isEmpty { folders.append(.folder("Imported from \(browser.displayName)", tree)) }
        }
        return folders
    }

    private static func insert(_ link: Bookmarks.Node, path: [String], into nodes: inout [Bookmarks.Node]) {
        guard let first = path.first else { nodes.append(link); return }
        if let index = nodes.firstIndex(where: { $0.isFolder && $0.title == first }) {
            var children = nodes[index].children ?? []
            insert(link, path: Array(path.dropFirst()), into: &children)
            nodes[index].children = children
        } else {
            var children: [Bookmarks.Node] = []
            insert(link, path: Array(path.dropFirst()), into: &children)
            nodes.append(.folder(first.isEmpty ? "Folder" : first, children))
        }
    }
}
