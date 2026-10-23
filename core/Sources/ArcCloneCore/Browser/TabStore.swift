import Foundation

/// Ordered tab collection for one window. Pinned tabs always sort before unpinned ones.
@MainActor
public final class TabStore {
    public struct ClosedTab: Sendable {
        let url: URL
        let pinned: Bool
        let index: Int
    }

    public private(set) var tabs: [Tab] = []
    public private(set) var activeID: UUID?
    public private(set) var recentlyClosed: [ClosedTab] = []

    public var onChange: (@MainActor () -> Void)?
    public var onActiveChange: (@MainActor (Tab?) -> Void)?
    public weak var tabDelegate: TabDelegate?

    private let factory: WebViewFactory
    private let router: IPCRouter
    private let maxRecentlyClosed = 25

    public init(factory: WebViewFactory, router: IPCRouter) {
        self.factory = factory
        self.router = router
    }

    public var active: Tab? { activeID.flatMap(tab) }

    public func tab(_ id: UUID) -> Tab? { tabs.first { $0.id == id } }

    @discardableResult
    public func create(url: URL?, activate: Bool = true, pinned: Bool = false, nextToActive: Bool = true) -> Tab {
        let tab = Tab(factory: factory, router: router, url: url, pinned: pinned)
        tab.delegate = tabDelegate
        let index: Int
        if pinned {
            index = tabs.lastIndex(where: \.isPinned).map { $0 + 1 } ?? 0
        } else if nextToActive, let active, let i = tabs.firstIndex(where: { $0 === active }), !active.isPinned {
            index = i + 1
        } else {
            index = tabs.count
        }
        tabs.insert(tab, at: index)
        if activate || activeID == nil { setActive(tab.id) } else { onChange?() }
        return tab
    }

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if let url = tab.url, url.scheme != "about" {
            recentlyClosed.append(ClosedTab(url: url, pinned: tab.isPinned, index: index))
            if recentlyClosed.count > maxRecentlyClosed { recentlyClosed.removeFirst() }
        }
        tab.tearDown()
        if activeID == id {
            // Arc-like: fall back to the most recently used remaining tab.
            let next = tabs.max(by: { $0.lastActivated < $1.lastActivated })
            setActive(next?.id)
        } else {
            onChange?()
        }
    }

    @discardableResult
    public func reopenClosed() -> Tab? {
        guard let closed = recentlyClosed.popLast() else { return nil }
        let tab = create(url: closed.url, activate: true, pinned: closed.pinned, nextToActive: false)
        move(tab.id, to: closed.index)
        return tab
    }

    public func activate(_ id: UUID) {
        guard tab(id) != nil else { return }
        setActive(id)
    }

    public func activate(index: Int) {
        guard tabs.indices.contains(index) else { return }
        setActive(tabs[index].id)
    }

    public func activateLast() {
        if let last = tabs.last { setActive(last.id) }
    }

    public func cycle(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == activeID } ?? 0
        let next = (current + offset % tabs.count + tabs.count) % tabs.count
        setActive(tabs[next].id)
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != pinned else { return }
        let tab = tabs.remove(at: index)
        tab.isPinned = pinned
        let pinnedEnd = tabs.lastIndex(where: \.isPinned).map { $0 + 1 } ?? 0
        tabs.insert(tab, at: pinnedEnd)
        onChange?()
    }

    /// Moves within the tab's own section (pinned / unpinned); the index is clamped.
    public func move(_ id: UUID, to requested: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let pinnedCount = tabs.filter(\.isPinned).count
        let range = tab.isPinned ? 0...pinnedCount : pinnedCount...tabs.count
        tabs.insert(tab, at: min(max(requested, range.lowerBound), range.upperBound))
        onChange?()
    }

    public func closeAll() {
        tabs.forEach { $0.tearDown() }
        tabs.removeAll()
        activeID = nil
    }

    private func setActive(_ id: UUID?) {
        let changed = activeID != id
        activeID = id
        active?.markActivated()
        if changed { onActiveChange?(active) }
        onChange?()
    }

    // MARK: Session

    public var session: SessionStore.Session {
        SessionStore.Session(
            tabs: tabs.compactMap { tab in
                guard let url = tab.url, url.scheme == "http" || url.scheme == "https" || url.isFileURL else { return nil }
                return .init(url: url, title: tab.title, pinned: tab.isPinned)
            },
            activeIndex: tabs.firstIndex { $0.id == activeID })
    }

    public func restore(_ session: SessionStore.Session) {
        for entry in session.tabs {
            let tab = create(url: entry.url, activate: false, pinned: entry.pinned, nextToActive: false)
            _ = tab
        }
        if let i = session.activeIndex, tabs.indices.contains(i) { setActive(tabs[i].id) }
        else if let first = tabs.first { setActive(first.id) }
    }
}

/// Persists window sessions as JSON in Application Support.
public struct SessionStore: Sendable {
    public struct Session: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public var url: URL
            public var title: String
            public var pinned: Bool
        }

        public var tabs: [Entry]
        public var activeIndex: Int?
    }

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("session.json")
    }

    public func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
