import AppKit
import Observation

/// Observable state behind one window's SwiftUI chrome (sidebar, command bar, toasts).
/// `BrowserWindowController` owns it and refreshes it from `TabStore`; views call back through it.
@MainActor @Observable
public final class WindowModel {
    public struct TabItem: Identifiable, Equatable {
        public let id: UUID
        var title: String
        var url: URL?
        var favicon: URL?
        var isLoading: Bool
        var isPinned: Bool
        var isYouTubeVideo: Bool
        var inSplit: Bool
        var isSleeping = false
    }

    var hasSplit = false
    var splitCanGrow = false
    var spaces: [Space] = []
    var currentSpaceID: UUID?
    /// Direction of the last space switch, for the slide transition.
    var spaceForward = true
    /// Horizontal offset of the tab list while a space swipe is in progress.
    var spaceDragOffset: CGFloat = 0
    var currentSpace: Space? { spaces.first { $0.id == currentSpaceID } }
    /// Every split group, in pane order; the active tab's group is the one on screen.
    var splitGroups: [SplitGroup] = []

    /// One row of the sidebar's tab list: a tab, or a split group drawn as a single pill.
    enum ListItem: Identifiable {
        case tab(TabItem)
        case split(SplitLayout, [TabItem])

        var id: String {
            switch self {
            case .tab(let tab): return tab.id.uuidString
            case .split(_, let tabs): return "split:" + tabs.map(\.id.uuidString).joined(separator: ",")
            }
        }
    }

    /// Regular tabs, with each split's members folded into one item at its first member's position.
    var regularItems: [ListItem] {
        var items: [ListItem] = []
        var placed = Set<Int>()
        for tab in regularTabs {
            if let index = splitGroups.firstIndex(where: { $0.tabIDs.contains(tab.id) }) {
                guard placed.insert(index).inserted else { continue }
                let group = splitGroups[index]
                items.append(.split(group.layout, group.tabIDs.compactMap { id in tabs.first { $0.id == id } }))
            } else {
                items.append(.tab(tab))
            }
        }
        return items
    }

    struct Toast: Equatable {
        let id = UUID()
        let message: String
        /// A button on the toast ("Restore"), which then stays up longer.
        var action: (title: String, run: @MainActor () -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    var tabs: [TabItem] = []
    var activeID: UUID?
    var canGoBack = false
    var canGoForward = false
    var canReopenClosed = false
    var selection: String?
    var toast: Toast?
    enum SidebarPanel { case tabs, assistant, history }
    var panel: SidebarPanel = .tabs
    var showsAssistant: Bool {
        get { panel == .assistant }
        set { panel = newValue ? .assistant : .tabs }
    }
    var commandBar: CommandBarModel?
    /// Where the downloads button sits (sidebar hosting-view coordinates), for the download animation.
    @ObservationIgnored var downloadsButtonFrame: CGRect = .zero
    let isPrivate: Bool
    let assistant: AssistantChat

    @ObservationIgnored weak var controller: BrowserWindowController?

    init(isPrivate: Bool, assistant: AssistantChat) {
        self.isPrivate = isPrivate
        self.assistant = assistant
    }

    var activeTab: TabItem? { tabs.first { $0.id == activeID } }
    var pinnedTabs: [TabItem] { tabs.filter(\.isPinned) }
    var regularTabs: [TabItem] { tabs.filter { !$0.isPinned } }

    /// Rebuilds the snapshot from the tab store; called once per coalesced change.
    func refresh(from store: TabStore) {
        let items = store.visibleTabs.map { tab in
            TabItem(id: tab.id, title: tab.title.isEmpty ? (tab.url?.host ?? "New Tab") : tab.title, url: tab.url,
                    favicon: tab.faviconURL, isLoading: tab.isLoading, isPinned: tab.isPinned,
                    isYouTubeVideo: tab.youtubeVideoID != nil, inSplit: store.splitGroup(containing: tab.id) != nil,
                    isSleeping: tab.isSleeping)
        }
        hasSplit = store.split != nil
        splitCanGrow = store.split?.layout.grown != nil
        if splitGroups != store.splits { splitGroups = store.splits }
        if items != tabs { tabs = items }
        if activeID != store.activeID { activeID = store.activeID }
        canGoBack = store.active?.webView.canGoBack ?? false
        canGoForward = store.active?.webView.canGoForward ?? false
        canReopenClosed = !store.recentlyClosed.isEmpty
        if spaces != store.spaces { spaces = store.spaces }
        if currentSpaceID != store.currentSpaceID { currentSpaceID = store.currentSpaceID }
    }

    func showToast(_ message: String, action: String? = nil, run: (@MainActor () -> Void)? = nil) {
        let toast = Toast(message: message, action: action.flatMap { title in run.map { (title, $0) } })
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.action == nil ? 2.2 : 8))
            if self?.toast == toast { self?.toast = nil }
        }
    }

    // MARK: Command bar

    /// ⌘T opens an empty bar for a new tab; ⌘L (or clicking the address) edits the current tab's URL.
    func presentCommandBar(newTab: Bool) {
        let seed = newTab ? "" : (activeTab?.url?.absoluteString ?? "")
        commandBar = CommandBarModel(newTab: newTab, query: seed, window: self)
        Haptics.tap()
    }

    /// ⌘K: tabs, history and bookmarks plus every browser command, space and extension.
    func presentCommandPalette() {
        commandBar = CommandBarModel(newTab: false, query: "", window: self, palette: true)
        Haptics.tap()
    }

    func dismissCommandBar() {
        commandBar = nil
        controller?.focusActivePage()
    }

    // MARK: Tab actions (forwarded to the controller)

    func activate(_ id: UUID) { controller?.tabs.activate(id) }
    func close(_ id: UUID) {
        controller?.tabs.close(id)
        Haptics.tap()
    }
    func newTab() { presentCommandBar(newTab: true) }
    func reopenClosed() {
        if controller?.tabs.reopenClosed() != nil { Haptics.tap() }
    }
    func goBack() { controller?.tabs.active?.goBack() }
    func goForward() { controller?.tabs.active?.goForward() }
    func reloadOrStop() {
        guard let tab = controller?.tabs.active else { return }
        if tab.isLoading { tab.stop() } else { tab.reload() }
    }
    func toggleSidebar() { controller?.toggleSidebar(nil) }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        controller?.tabs.setPinned(id, pinned)
        Haptics.step()
    }

    /// Moves a regular-list row; a split group moves as one block.
    func moveItems(from source: IndexSet, to destination: Int) {
        let items = regularItems
        guard let first = source.first else { return }
        switch items[first] {
        case .tab(let tab): moveRegular([tab.id], toRow: destination)
        case .split(_, let members): moveRegular(members.map(\.id), toRow: destination)
        }
        Haptics.snap()
    }

    /// Puts `ids` (in order) before the regular-list row at `destination` (or at the end).
    private func moveRegular(_ ids: [UUID], toRow destination: Int) {
        let items = regularItems
        guard let store = controller?.tabs else { return }
        let anchorTab: UUID? = destination < items.count ? {
            switch items[destination] { case .tab(let t): return t.id; case .split(_, let m): return m.first?.id }
        }() : nil
        var target = anchorTab.flatMap { id in store.tabs.firstIndex { $0.id == id } } ?? store.tabs.count
        for id in ids {
            guard let current = store.tabs.firstIndex(where: { $0.id == id }) else { continue }
            if current < target { target -= 1 }
            store.move(id, to: target)
            target += 1
        }
    }

    // MARK: Drag and drop (TabDragDrop.swift)

    /// Dropped between regular rows: a tab moves there (a pinned one is unpinned); a link opens there.
    func dropInList(_ drop: TabDrop, atRow row: Int) {
        guard let store = controller?.tabs else { return }
        switch drop {
        case .tab(let id):
            guard let tab = store.tab(id), tab.spaceID == store.currentSpaceID else { return }
            if tab.isPinned { store.setPinned(id, false) }
            moveRegular([id], toRow: row)
            Haptics.snap()
        case .link:
            guard let url = drop.webLink else { return }
            let tab = store.create(url: url, activate: true, nextToActive: false)
            moveRegular([tab.id], toRow: row)
            Haptics.step()
        }
    }

    /// Dropped among the pinned tiles: a tab is pinned (or reordered) before `target`, or after the
    /// last pinned tab when it's nil; a link opens pinned there.
    func dropOnPinned(_ drop: TabDrop, before target: UUID?) -> Bool {
        guard let store = controller?.tabs else { return false }
        let id: UUID
        switch drop {
        case .tab(let dragged):
            guard dragged != target, let tab = store.tab(dragged), tab.spaceID == store.currentSpaceID else { return false }
            if !tab.isPinned { store.setPinned(dragged, true) }
            id = dragged
        case .link:
            guard let url = drop.webLink else { return false }
            id = store.create(url: url, activate: true, pinned: true).id
        }
        // `move` removes the tab before inserting it, so moving it rightward lands one earlier than
        // the target's current index; past the end, it clamps to after the last pinned tab.
        var index = target.flatMap { target in store.tabs.firstIndex { $0.id == target } } ?? store.tabs.count
        if let from = store.tabs.firstIndex(where: { $0.id == id }), from < index { index -= 1 }
        store.move(id, to: index)
        Haptics.step()
        return true
    }

    /// Dropped on a space in the switcher: a tab moves there; a link opens there, unloaded until used.
    func dropOnSpace(_ drop: TabDrop, space: UUID) -> Bool {
        guard let store = controller?.tabs else { return false }
        switch drop {
        case .tab(let id):
            guard let tab = store.tab(id), tab.spaceID != space else { return false }
            store.moveTab(id, toSpace: space)
        case .link:
            guard let url = drop.webLink else { return false }
            store.createAsleep(url: url, title: url.host ?? url.absoluteString, pinned: false, in: space)
        }
        let name = spaces.first { $0.id == space }?.name ?? "space"
        showToast(drop.webLink == nil ? "Moved to \(name)" : "Opened in \(name)")
        Haptics.step()
        return true
    }

    /// Dropped on a split pill: the tab joins that split.
    func dropOnSplit(_ drop: TabDrop, joining member: UUID) -> Bool {
        guard case .tab(let id) = drop, let store = controller?.tabs, store.splitGroup(containing: member)?.tabIDs.contains(id) == false,
              store.tab(id)?.spaceID == store.currentSpaceID else { return false }
        store.activate(member)
        store.addToSplit(id)
        Haptics.step()
        return store.splitGroup(containing: member)?.tabIDs.contains(id) == true
    }

    /// Moves within a section (pinned or regular), as reported by SwiftUI's `onMove`.
    func move(in section: [TabItem], from source: IndexSet, to destination: Int) {
        guard let store = controller?.tabs, let first = source.first else { return }
        let moving = section[first]
        var reordered = section
        reordered.move(fromOffsets: source, toOffset: destination)
        guard let newIndex = reordered.firstIndex(of: moving),
              let anchorIndex = store.tabs.firstIndex(where: { $0.id == (section.first?.id ?? moving.id) }) else { return }
        store.move(moving.id, to: anchorIndex + newIndex)
        Haptics.snap()
    }

    // MARK: Spaces

    func switchSpace(to id: UUID) {
        guard id != currentSpaceID else { return }
        controller?.tabs.switchSpace(to: id)
        Haptics.step()
    }
    func switchSpace(by offset: Int) {
        controller?.tabs.switchSpace(by: offset)
        Haptics.step()
    }
    func addSpace(_ space: Space) {
        controller?.tabs.addSpace(name: space.name, symbol: space.symbol, color: space.color, separateLogins: space.hasSeparateLogins)
        Haptics.step()
    }
    func updateSpace(_ space: Space) { controller?.tabs.updateSpace(space) }
    func deleteSpace(_ id: UUID) { controller?.tabs.deleteSpace(id) }
    func moveTab(_ id: UUID, toSpace space: UUID) { controller?.tabs.moveTab(id, toSpace: space) }

    // MARK: Split view

    /// Splits the active tab side by side with `id`.
    func splitWithActive(_ id: UUID) {
        controller?.tabs.makeSplit(.twoColumns, with: [id])
    }

    func addToSplit(_ id: UUID) { controller?.tabs.addToSplit(id) }
    func removeFromSplit(_ id: UUID) { controller?.tabs.removeFromSplit(id) }

    func duplicate(_ id: UUID) {
        guard let store = controller?.tabs, let url = store.tab(id)?.url else { return }
        store.create(url: url)
    }

    func reload(_ id: UUID) { controller?.tabs.tab(id)?.reload() }

    func copyLink(_ id: UUID) {
        guard let url = controller?.tabs.tab(id)?.url else { return }
        Clipboard.copy(url.absoluteString, sensitive: isPrivate)
        showToast("Link copied")
        Haptics.tap()
    }

    func pauseMedia(_ id: UUID) {
        guard let tab = controller?.tabs.tab(id), tab.hasWebView else { return }
        tab.webView.pauseAllMediaPlayback()
    }

    func openInNewWindow(_ id: UUID) {
        guard let url = controller?.tabs.tab(id)?.url else { return }
        (NSApp.delegate as? AppDelegate)?.openInNewWindow(url, isPrivate: isPrivate)
    }

    func closeOthers(_ id: UUID) {
        guard let store = controller?.tabs else { return }
        store.visibleTabs.filter { $0.id != id && !$0.isPinned }.forEach { store.close($0.id) }
        Haptics.tap()
    }

    func closeBelow(_ id: UUID) {
        guard let store = controller?.tabs else { return }
        let visible = store.visibleTabs
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        visible[(index + 1)...].filter { !$0.isPinned }.forEach { store.close($0.id) }
        Haptics.tap()
    }
}

/// Force Touch trackpad feedback for important actions. macOS only plays it while a finger is on
/// a Force Touch trackpad, so it accompanies gestures and clicks, never keyboard shortcuts alone.
/// Settings → General can turn it off.
enum Haptics {
    /// A light click: an action happened (close, open, copy).
    @MainActor static func tap() { perform(.generic) }
    /// Something snapped into place or crossed a threshold (reorder, swipe threshold, zoom limit).
    @MainActor static func snap() { perform(.alignment) }
    /// A change of level or mode (space switched, split created, pinned, dark mode).
    @MainActor static func step() { perform(.levelChange) }

    @MainActor static var isEnabled: Bool { Preferences.flag(Preferences.Key.haptics, default: true) }

    @MainActor static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
