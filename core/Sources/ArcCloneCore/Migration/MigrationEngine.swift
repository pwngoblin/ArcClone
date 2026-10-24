import Foundation

/// Where every migration file read and SQLite query runs: off the main thread, one at a time.
@globalActor
actor MigrationActor {
    static let shared = MigrationActor()
}

/// Finds and reads other browsers' data inside folders the user granted.
enum MigrationEngine {
    /// The browser's own folder inside the granted folders, if it's there.
    static func locate(_ browser: SourceBrowser, in granted: [MigrationRoot: URL]) -> URL? {
        guard let root = granted[browser.root] else { return nil }
        let folder = browser.relativePath.isEmpty ? root : root.appendingPathComponent(browser.relativePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return folder
    }

    /// Counts what's there, for the browser cards.
    @MigrationActor
    static func scan(_ browser: SourceBrowser, folder: URL) throws -> BrowserScan {
        switch browser.engine {
        case .chromium:
            let userData = browser.userDataPath.isEmpty ? folder : folder.appendingPathComponent(browser.userDataPath, isDirectory: true)
            let profiles = try ChromiumReader.profiles(in: userData)
            let bookmarks = try profiles.reduce(0) { $0 + (try ChromiumReader.bookmarks(profile: $1)).count }
            let history = profiles.reduce(0) { $0 + ChromiumReader.historyCount(profile: $1) }
            let spaces = browser.supportsSpaces ? (try? ArcSidebarReader.spaces(in: folder))?.count ?? 0 : 0
            return BrowserScan(bookmarks: bookmarks, history: history, spaces: spaces)
        case .safari:
            return BrowserScan(bookmarks: try SafariReader.bookmarks(in: folder).count, history: SafariReader.historyCount(in: folder), spaces: 0)
        case .firefox:
            let counts = try FirefoxReader.profiles(in: folder).map(FirefoxReader.counts(profile:))
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
