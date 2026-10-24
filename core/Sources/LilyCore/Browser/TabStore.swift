import Foundation

/// A named group of tabs (Arc's Spaces): each has its own pinned and regular tabs, icon and color.
public struct Space: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var color: String
    /// Separate logins: the space's tabs have their own cookies, storage and cache, so you can be
    /// signed in to a site with different accounts in different spaces. Optional so sessions
    /// saved before it existed still decode.
    public var separateLogins: Bool?
    public var hasSeparateLogins: Bool { separateLogins ?? false }

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

    public private(set) var tabs: [Tab] = [] { didSet { byID = nil } }
    /// id → tab, rebuilt lazily after the list changes; lookups happen far more often than changes.
    private var byID: [UUID: Tab]?
    public private(set) var activeID: UUID?
    public private(set) var recentlyClosed: [ClosedTab] = []

    public func clearRecentlyClosed() { recentlyClosed.removeAll() }

    /// Every split group; a tab belongs to at most one. Each shows as one pill in the sidebar.
    public private(set) var splits: [SplitGroup] = [] {
        didSet { if splits != oldValue { onSplitChange?(); onChange?() } }
    }
    /// The split the active tab is in, which is the one on screen.
    public var split: SplitGroup? { activeID.flatMap(splitGroup(containing:)) }

    public func splitGroup(containing id: UUID) -> SplitGroup? { splits.first { $0.tabIDs.contains(id) } }

    /// Takes a tab out of whatever split it's in (the group shrinks or ends).
    private func leaveSplit(_ id: UUID) {
        guard let index = splits.firstIndex(where: { $0.tabIDs.contains(id) }) else { return }
        if let smaller = splits[index].removing(id) { splits[index] = smaller } else { splits.remove(at: index) }
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

    public func tab(_ id: UUID) -> Tab? {
        if byID == nil { byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        return byID?[id]
    }

    @discardableResult
    /// `nextToActive: nil` follows Settings → Tabs ("Open new tabs next to the current tab").
    public func create(url: URL?, activate: Bool = true, pinned: Bool = false, nextToActive: Bool? = nil) -> Tab {
        let nextToActive = nextToActive ?? Preferences.opensTabsNextToCurrent
        let tab = Tab(factory: factory, router: router, url: url, pinned: pinned, space: currentSpaceID)
        return insert(tab, activate: activate, pinned: pinned, nextToActive: nextToActive)
    }

    /// Imported tabs: added to `space`, unloaded until first used, without switching to them.
    @discardableResult
    public func createAsleep(url: URL, title: String, pinned: Bool, in space: UUID) -> Tab {
        let tab = Tab(factory: factory, router: router, url: url, pinned: pinned, space: space,
                      asleepWithTitle: title.isEmpty ? (url.host ?? url.absoluteString) : title)
        tab.delegate = tabDelegate
        let index = pinned ? (tabs.lastIndex(where: \.isPinned).map { $0 + 1 } ?? 0) : tabs.count
        tabs.insert(tab, at: index)
        onTabAdded?(tab)
        onChange?()
        return tab
    }

    private func insert(_ tab: Tab, activate: Bool, pinned: Bool, nextToActive: Bool) -> Tab {
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
        leaveSplit(id)
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
    public func addSpace(name: String, symbol: String, color: String, separateLogins: Bool = false, activate: Bool = true) -> Space {
        var space = Space(name: name.isEmpty ? "Space \(spaces.count + 1)" : String(name.prefix(40)), symbol: symbol, color: color)
        if separateLogins {
            space.separateLogins = true
            factory.setSeparateLogins(true, forSpace: space.id)
        }
        spaces.append(space)
        if activate { switchSpace(to: space.id) } else { onChange?() }
        return space
    }

    public func updateSpace(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        let switchedStore = spaces[index].hasSeparateLogins != space.hasSeparateLogins
        spaces[index] = space
        if switchedStore {
            factory.setSeparateLogins(space.hasSeparateLogins, forSpace: space.id)
            tabs.filter { $0.spaceID == space.id }.forEach { $0.rebuildWebView() }
            if active?.spaceID == space.id { onActiveChange?(active) }
        }
        onChange?()
    }

    /// Deletes a space and closes its tabs; the last space can't be deleted.
    public func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        if id == currentSpaceID { switchSpace(to: spaces[index == 0 ? 1 : index - 1].id) }
        tabs.filter { $0.spaceID == id }.forEach { close($0.id) }
        let separate = spaces.remove(at: index).hasSeparateLogins
        lastActive[id] = nil
        onChange?()
        // Its tabs are gone, so its logins and site data go too.
        if separate { Task { [factory] in await factory.removeSpaceData(id) } }
    }

    public func moveTab(_ id: UUID, toSpace space: UUID) {
        guard let tab = tab(id), tab.spaceID != space, spaces.contains(where: { $0.id == space }) else { return }
        leaveSplit(id)
        let store = factory.dataStore(forSpace: tab.spaceID)
        tab.spaceID = space
        // Cookies don't follow a tab into a space with a different store; it reloads there.
        if factory.dataStore(forSpace: space) !== store { tab.rebuildWebView() }
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

    /// With the active tab outside a split: starts a new split of it, the requested tabs, then the
    /// following tabs that aren't in another split (wrapping around), opening blank tabs when there
    /// aren't enough. Existing splits are left alone.
    /// With the active tab in a split: requested tabs join that split; without any, the split
    /// changes to `layout`, filling or dropping panes at the end.
    @discardableResult
    public func makeSplit(_ layout: SplitLayout, with requested: [UUID] = []) -> SplitGroup? {
        guard let active else { return nil }
        let requested = requested.filter { $0 != active.id && tab($0) != nil }
        if let index = splits.firstIndex(where: { $0.tabIDs.contains(active.id) }) {
            if !requested.isEmpty {
                for id in requested { addToSplit(id) }
                activate(active.id)
                return split
            }
            var ids = splits[index].tabIDs
            ids = Array(ids.prefix(layout.paneCount)) + fill(layout.paneCount - ids.count, after: active, excluding: ids)
            splits[index].layout = layout
            splits[index].tabIDs = ids
            return splits[index]
        }
        requested.forEach(leaveSplit)
        var ids = [active.id] + requested
        ids = Array(ids.prefix(layout.paneCount))
        ids += fill(layout.paneCount - ids.count, after: active, excluding: ids)
        let group = SplitGroup(layout: layout, tabIDs: ids)
        splits.append(group)
        return group
    }

    /// `count` tabs for new panes: the regular tabs after `anchor` in this space that aren't in a
    /// split (wrapping around), then blank tabs.
    private func fill(_ count: Int, after anchor: Tab, excluding taken: [UUID]) -> [UUID] {
        guard count > 0 else { return [] }
        let free = tabs.filter { !$0.isPinned && !taken.contains($0.id) && $0.spaceID == currentSpaceID && splitGroup(containing: $0.id) == nil }
        let anchorIndex = tabs.firstIndex(of: anchor) ?? 0
        let start = free.firstIndex { tabs.firstIndex(of: $0)! > anchorIndex } ?? 0
        var ids = (free[start...] + free[..<start]).prefix(count).map(\.id)
        while ids.count < count { ids.append(create(url: nil, activate: false, nextToActive: false).id) }
        return ids
    }

    /// Adds a tab to the active tab's split (moving it out of any other split) and shows it.
    public func addToSplit(_ id: UUID) {
        guard let activeID, let index = splits.firstIndex(where: { $0.tabIDs.contains(activeID) }),
              !splits[index].tabIDs.contains(id), splits[index].layout.grown != nil else { return }
        leaveSplit(id)
        guard let target = splits.firstIndex(where: { $0.tabIDs.contains(activeID) }), let grown = splits[target].adding(id) else { return }
        splits[target] = grown
        activate(id)
    }

    public func removeFromSplit(_ id: UUID) { leaveSplit(id) }

    /// Link Scrolling for the split on screen.
    public func setScrollLinked(_ linked: Bool) {
        guard let activeID, let index = splits.firstIndex(where: { $0.tabIDs.contains(activeID) }) else { return }
        splits[index].scrollLinked = linked
    }

    /// Ends the split on screen; other splits stay.
    public func exitSplit() {
        guard let activeID else { return }
        splits.removeAll { $0.tabIDs.contains(activeID) }
    }

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
            for space in saved where space.hasSeparateLogins { factory.setSeparateLogins(true, forSpace: space.id) }
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
                // Restored tabs load when first opened, not all at launch.
                createAsleep(url: entry.url, title: entry.title, pinned: entry.pinned, in: currentSpaceID)
            }
        }
        currentSpaceID = restoring
        if let i = session.activeIndex, tabs.indices.contains(i), tabs[i].spaceID == currentSpaceID { setActive(tabs[i].id) }
        else { setActive(visibleTabs.first?.id) }
    }
}
