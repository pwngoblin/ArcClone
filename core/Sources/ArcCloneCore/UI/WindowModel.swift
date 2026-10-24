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

    func showToast(_ message: String) {
        let toast = Toast(message: message)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
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
        guard let store = controller?.tabs, let first = source.first else { return }
        let ids: [UUID]
        switch items[first] {
        case .tab(let tab): ids = [tab.id]
        case .split(_, let members): ids = members.map(\.id)
        }
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
        Haptics.snap()
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
    func addSpace(name: String, symbol: String, color: String) {
        controller?.tabs.addSpace(name: name, symbol: symbol, color: color)
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

    /// Drag between pinned tiles.
    func movePinned(_ id: UUID, before target: UUID) {
        guard id != target, let store = controller?.tabs, store.tab(id)?.isPinned == true,
              let index = store.tabs.firstIndex(where: { $0.id == target }) else { return }
        store.move(id, to: index)
        Haptics.snap()
    }

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
        controller?.tabs.tab(id)?.webView.pauseAllMediaPlayback()
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
