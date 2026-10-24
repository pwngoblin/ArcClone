import AppKit
import Observation

/// State behind the import window: which browsers were found, what to bring over, and progress.
/// File work happens on `MigrationActor`; this only coordinates and updates the UI.
@MainActor @Observable
final class MigrationModel {
    enum Status: Equatable {
        case needsAccess
        case scanning
        /// Where it looked (home-relative), so a grant of the wrong folder is easy to spot.
        case notFound(looked: String)
        /// Its folder is there but holds no bookmarks, history or spaces.
        case empty
        case found(BrowserScan)
        case unreadable(String)
    }

    struct Card: Identifiable {
        let browser: SourceBrowser
        var status: Status = .needsAccess
        var selected = false
        var options = MigrationOptions()
        var expanded = false
        var id: String { browser.id }

        var isAvailable: Bool { if case .found = status { return true }; return false }
    }

    struct Summary: Equatable {
        var browsers: [String] = []
        var bookmarks = 0
        var history = 0
        var olderThanRetention = 0
        var spaces = 0
        var tabs = 0
        var problems: [String] = []
    }

    enum Phase: Equatable {
        case idle
        case importing(step: String, progress: Double)
        case done(Summary)
    }

    /// Where imported data goes.
    struct Destination {
        let bookmarks: Bookmarks
        let history: History?
        let tabs: () -> TabStore?
    }

    private(set) var cards: [Card] = SourceBrowser.allCases.map { Card(browser: $0) }
    private(set) var phase: Phase = .idle
    private(set) var grantedRoots: Set<MigrationRoot> = []
    private let access: MigrationAccess
    private let destination: Destination
    private static let spaceColors = ["#5B4CF5", "#0A84FF", "#30B0C7", "#34C759", "#FF9F0A", "#FF375F"]

    init(access: MigrationAccess, destination: Destination) {
        self.access = access
        self.destination = destination
    }

    var canImport: Bool { phase == .idle && cards.contains { $0.selected && $0.isAvailable && ($0.options.bookmarks || $0.options.history || $0.options.spaces) } }

    func binding(_ id: String) -> Card? { cards.first { $0.id == id } }

    func update(_ id: String, _ change: (inout Card) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }

    /// On appearance: restore earlier grants and look for browsers.
    func appear() async {
        await access.load()
        await scan()
    }

    func grant(_ root: MigrationRoot) async {
        guard await access.grant(root) else { return }
        await scan()
    }

    /// Counts each browser's bookmarks and history inside the granted folders.
    func scan() async {
        grantedRoots = Set(MigrationRoot.allCases.filter(access.isGranted))
        for index in cards.indices {
            cards[index].status = grantedRoots.contains(cards[index].browser.root) ? .scanning : .needsAccess
        }
        await access.withAccess { roots in
            for index in cards.indices where cards[index].status == .scanning {
                let browser = cards[index].browser
                guard let folder = MigrationEngine.locate(browser, in: roots) else {
                    let granted = roots[browser.root] ?? roots.values.first
                    cards[index].status = .notFound(looked: granted.map(Self.homeRelative) ?? browser.root.displayPath)
                    continue
                }
                do {
                    let scan = try await MigrationEngine.scan(browser, folder: folder)
                    cards[index].status = scan.bookmarks + scan.history + scan.spaces > 0 ? .found(scan) : .empty
                    cards[index].selected = cards[index].isAvailable
                    cards[index].options.spaces = browser.supportsSpaces && scan.spaces > 0
                } catch {
                    cards[index].status = .unreadable(Self.explain(error, browser: browser))
                    Log.app.error("Scanning \(browser.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// Reads every selected browser, de-duplicates, and saves into Lily.
    func start() async {
        let chosen = cards.filter { $0.selected && $0.isAvailable }
        guard !chosen.isEmpty, phase == .idle else { return }
        let steps = Double(chosen.reduce(0) { $0 + [$1.options.bookmarks, $1.options.history, $1.options.spaces && $1.browser.supportsSpaces].filter { $0 }.count } + 2)
        var done = 0.0
        func step(_ text: String) {
            phase = .importing(step: text, progress: done / steps)
            done += 1
        }
        var summary = Summary()
        var bookmarkSources: [(SourceBrowser, [ImportedBookmark])] = []
        var historySources: [[ImportedVisit]] = []
        var spaces: [ImportedSpace] = []

        await access.withAccess { roots in
            for card in chosen {
                let browser = card.browser
                guard let folder = MigrationEngine.locate(browser, in: roots) else { continue }
                do {
                    if card.options.bookmarks {
                        step("Reading \(browser.displayName) bookmarks…")
                        bookmarkSources.append((browser, try await MigrationEngine.readBookmarks(browser, folder: folder)))
                    }
                    if card.options.history {
                        step("Reading \(browser.displayName) history…")
                        historySources.append(try await MigrationEngine.readHistory(browser, folder: folder))
                    }
                    if card.options.spaces && browser.supportsSpaces {
                        step("Reading \(browser.displayName) spaces and tabs…")
                        spaces += try await MigrationEngine.readSpaces(browser, folder: folder)
                    }
                    summary.browsers.append(browser.displayName)
                } catch {
                    summary.problems.append("\(browser.displayName): \(Self.explain(error, browser: browser))")
                }
            }
        }

        step("Removing duplicates…")
        let folders = MigrationMerger.bookmarkFolders(bookmarkSources)
        var visits = MigrationMerger.mergeHistory(historySources)
        if let history = destination.history, history.retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(history.retentionDays) * 86_400)
            let recent = visits.filter { $0.lastVisit >= cutoff }
            summary.olderThanRetention = visits.count - recent.count
            visits = recent
        }

        step("Saving…")
        for folder in folders { summary.bookmarks += destination.bookmarks.addFolder(folder) }
        if let history = destination.history, !visits.isEmpty {
            summary.history = history.importVisits(visits.map { ($0.url, $0.title, $0.lastVisit) })
        }
        if let tabs = destination.tabs(), !spaces.isEmpty {
            for (index, imported) in spaces.enumerated() {
                let space = tabs.addSpace(name: imported.name, symbol: "square.stack", color: Self.spaceColors[index % Self.spaceColors.count], activate: false)
                for tab in imported.tabs { tabs.createAsleep(url: URLNormalizer.clean(tab.url) ?? tab.url, title: tab.title, pinned: tab.pinned, in: space.id) }
                summary.spaces += 1
                summary.tabs += imported.tabs.count
            }
        }
        Log.app.info("Import finished: \(summary.bookmarks, privacy: .public) bookmarks, \(summary.history, privacy: .public) history entries, \(summary.tabs, privacy: .public) tabs from \(summary.browsers.count, privacy: .public) browsers")
        phase = .done(summary)
        Haptics.snap()
    }

    func reset() {
        phase = .idle
    }

    /// `/Users/me/Library/Application Support` → `~/Library/Application Support`.
    static func homeRelative(_ url: URL) -> String {
        let home = MigrationAccess.realHome.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Plain-language reasons; Safari's folder is protected by macOS beyond the sandbox.
    static func explain(_ error: Error, browser: SourceBrowser) -> String {
        let ns = error as NSError
        let denied = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError) || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(EPERM))
        if denied {
            return "macOS protects \(browser.displayName)'s data. Allow Lily in System Settings → Privacy & Security → Full Disk Access, then scan again."
        }
        return Sanitize.errorMessage(error)
    }
}
