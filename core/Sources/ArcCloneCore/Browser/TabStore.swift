import Foundation

/// A named group of tabs (Arc's Spaces): each has its own pinned and regular tabs, icon and color.
public struct Space: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var color: String

    public init(id: UUID = UUID(), name: String, symbol: String = "circle.fill", color: String = "#5B4CF5") {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
    }

    static let symbols = ["circle.fill", "house.fill", "briefcase.fill", "book.fill", "gamecontroller.fill", "music.note",
                          "paintbrush.fill", "graduationcap.fill", "cart.fill", "airplane", "heart.fill", "star.fill"]
}

/// Ordered tab collection for one window, divided into spaces. `tabs` holds every space's tabs;
/// `visibleTabs` is the current space. Pinned tabs always sort before unpinned ones.
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

    public func clearRecentlyClosed() { recentlyClosed.removeAll() }

    /// Tabs currently shown together in split view.
    public private(set) var split: SplitGroup? {
        didSet { if split != oldValue { onSplitChange?(); onChange?() } }
    }
    public var onSplitChange: (@MainActor () -> Void)?

    public private(set) var spaces: [Space] = [Space(name: "Personal", symbol: "house.fill")]
    public private(set) var currentSpaceID: UUID
    /// Last active tab per space, restored when switching back.
    private var lastActive: [UUID: UUID] = [:]
    public var onSpaceChange: (@MainActor (_ forward: Bool) -> Void)?

    public var currentSpace: Space { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }
    public var visibleTabs: [Tab] { tabs.filter { $0.spaceID == currentSpaceID } }

    public var onChange: (@MainActor () -> Void)?
    public var onActiveChange: (@MainActor (Tab?) -> Void)?
    /// Tab lifecycle, for the web extension APIs.
    public var onTabAdded: (@MainActor (Tab) -> Void)?
    public var onTabRemoved: (@MainActor (Tab) -> Void)?
    public var onActiveTabSwitched: (@MainActor (_ new: Tab?, _ previous: Tab?) -> Void)?
    public weak var tabDelegate: TabDelegate?

    private let factory: WebViewFactory
    private let router: IPCRouter
    private let maxRecentlyClosed = 25

    public init(factory: WebViewFactory, router: IPCRouter) {
        self.factory = factory
        self.router = router
        self.currentSpaceID = spaces[0].id
    }

    public var active: Tab? { activeID.flatMap(tab) }

    public func tab(_ id: UUID) -> Tab? { tabs.first { $0.id == id } }

    @discardableResult
    /// `nextToActive: nil` follows Settings → Tabs ("Open new tabs next to the current tab").
    public func create(url: URL?, activate: Bool = true, pinned: Bool = false, nextToActive: Bool? = nil) -> Tab {
        let nextToActive = nextToActive ?? Preferences.opensTabsNextToCurrent
        let tab = Tab(factory: factory, router: router, url: url, pinned: pinned)
        tab.spaceID = currentSpaceID
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
        onTabAdded?(tab)
        if activate || activeID == nil { setActive(tab.id) } else { onChange?() }
        return tab
    }

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let split, split.tabIDs.contains(id) { self.split = split.removing(id) }
        let tab = tabs.remove(at: index)
        if let url = tab.url, url.scheme != "about" {
            recentlyClosed.append(ClosedTab(url: url, pinned: tab.isPinned, index: index))
            if recentlyClosed.count > maxRecentlyClosed { recentlyClosed.removeFirst() }
        }
        onTabRemoved?(tab)
        router.forget(tab: tab.id)
        tab.tearDown()
        if activeID == id {
            // Arc-like: fall back to the most recently used remaining tab in this space.
            let next = visibleTabs.max(by: { $0.lastActivated < $1.lastActivated })
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

    /// Activating a tab from another space switches to that space.
    public func activate(_ id: UUID) {
        guard let tab = tab(id) else { return }
        if tab.spaceID != currentSpaceID, let index = spaces.firstIndex(where: { $0.id == tab.spaceID }) {
            let forward = index > (spaces.firstIndex { $0.id == currentSpaceID } ?? 0)
            lastActive[currentSpaceID] = activeID
            currentSpaceID = tab.spaceID
            onSpaceChange?(forward)
        }
        setActive(id)
    }

    public func activate(index: Int) {
        let visible = visibleTabs
        guard visible.indices.contains(index) else { return }
        setActive(visible[index].id)
    }

    public func activateLast() {
        if let last = visibleTabs.last { setActive(last.id) }
    }

    public func cycle(by offset: Int) {
        let visible = visibleTabs
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == activeID } ?? 0
        let next = (current + offset % visible.count + visible.count) % visible.count
        setActive(visible[next].id)
    }

    // MARK: Spaces

    public func switchSpace(to id: UUID) {
        guard id != currentSpaceID, let target = spaces.firstIndex(where: { $0.id == id }) else { return }
        let forward = target > (spaces.firstIndex { $0.id == currentSpaceID } ?? 0)
        lastActive[currentSpaceID] = activeID
        currentSpaceID = id
        let remembered = lastActive[id].flatMap(tab).flatMap { $0.spaceID == id ? $0 : nil }
        onSpaceChange?(forward)
        setActive((remembered ?? visibleTabs.max { $0.lastActivated < $1.lastActivated })?.id)
    }

    /// Next/previous space, wrapping around.
    public func switchSpace(by offset: Int) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        switchSpace(to: spaces[(index + offset % spaces.count + spaces.count) % spaces.count].id)
    }

    @discardableResult
    public func addSpace(name: String, symbol: String, color: String) -> Space {
        let space = Space(name: name.isEmpty ? "Space \(spaces.count + 1)" : String(name.prefix(40)), symbol: symbol, color: color)
        spaces.append(space)
        switchSpace(to: space.id)
        return space
    }

    public func updateSpace(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        spaces[index] = space
        onChange?()
    }

    /// Deletes a space and closes its tabs; the last space can't be deleted.
    public func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        if id == currentSpaceID { switchSpace(to: spaces[index == 0 ? 1 : index - 1].id) }
        tabs.filter { $0.spaceID == id }.forEach { close($0.id) }
        spaces.remove(at: index)
        lastActive[id] = nil
        onChange?()
    }

    public func moveTab(_ id: UUID, toSpace space: UUID) {
        guard let tab = tab(id), tab.spaceID != space, spaces.contains(where: { $0.id == space }) else { return }
        if let split, split.tabIDs.contains(id) { self.split = split.removing(id) }
        tab.spaceID = space
        if activeID == id { setActive(visibleTabs.max { $0.lastActivated < $1.lastActivated }?.id) } else { onChange?() }
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
        let previous = active
        activeID = id
        if changed { onActiveTabSwitched?(active, previous) }
        active?.markActivated()
        if changed { onActiveChange?(active) }
        onChange?()
    }

    // MARK: Session

    public var session: SessionStore.Session {
        let saved: [Tab] = tabs.filter { tab in
            guard let url = tab.url else { return false }
            return url.isFileURL ? tab.fileBookmark != nil : (url.scheme == "http" || url.scheme == "https")
        }
        return SessionStore.Session(
            tabs: saved.map { tab in
                .init(url: tab.url!, title: tab.title, pinned: tab.isPinned, bookmark: tab.url!.isFileURL ? tab.fileBookmark : nil, space: tab.spaceID)
            },
            activeIndex: saved.firstIndex { $0.id == activeID },
            spaces: spaces,
            currentSpace: currentSpaceID)
    }

    // MARK: Split view

    /// Splits the active tab with the tabs after it (wrapping around), opening blank tabs when
    /// there aren't enough. Returns the new group.
    @discardableResult
    public func makeSplit(_ layout: SplitLayout, with requested: [UUID] = []) -> SplitGroup? {
        guard let active else { return nil }
        var ids = [active.id] + requested.filter { $0 != active.id && tab($0) != nil }
        let others = tabs.filter { !$0.isPinned && !ids.contains($0.id) && $0.spaceID == currentSpaceID }
        let start = others.firstIndex { tab in tabs.firstIndex(of: tab)! > tabs.firstIndex(of: active)! } ?? 0
        for tab in (others[start...] + others[..<start]) where ids.count < layout.paneCount { ids.append(tab.id) }
        while ids.count < layout.paneCount {
            ids.append(create(url: nil, activate: false, nextToActive: false).id)
        }
        split = SplitGroup(layout: layout, tabIDs: Array(ids.prefix(layout.paneCount)))
        return split
    }

    public func addToSplit(_ id: UUID) {
        guard let grown = split?.adding(id) else { return }
        split = grown
        activate(id)
    }

    public func removeFromSplit(_ id: UUID) {
        guard let split, split.tabIDs.contains(id) else { return }
        self.split = split.removing(id)
    }

    public func exitSplit() { split = nil }

    /// Opens a local file the user chose (Open panel, Finder, or a restored bookmark).
    @discardableResult
    public func openFile(_ url: URL, activate: Bool = true, pinned: Bool = false) -> Tab {
        let tab = create(url: nil, activate: activate, pinned: pinned, nextToActive: false)
        tab.holdSecurityScope(url)
        tab.load(url)
        return tab
    }

    public func restore(_ session: SessionStore.Session) {
        if let saved = session.spaces, !saved.isEmpty {
            spaces = saved
            currentSpaceID = session.currentSpace.flatMap { id in saved.first { $0.id == id }?.id } ?? saved[0].id
        }
        let known = Set(spaces.map(\.id))
        let restoring = currentSpaceID
        for entry in session.tabs {
            currentSpaceID = entry.space.flatMap { known.contains($0) ? $0 : nil } ?? spaces[0].id
            if entry.url.isFileURL {
                guard let bookmark = entry.bookmark else { continue }
                var stale = false
                guard let file = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else { continue }
                openFile(file, activate: false, pinned: entry.pinned)
            } else {
                create(url: entry.url, activate: false, pinned: entry.pinned, nextToActive: false)
            }
        }
        currentSpaceID = restoring
        if let i = session.activeIndex, tabs.indices.contains(i), tabs[i].spaceID == currentSpaceID { setActive(tabs[i].id) }
        else { setActive(visibleTabs.first?.id) }
    }
}
