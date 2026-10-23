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
        var progress: Double
        var isPinned: Bool
        var isYouTubeVideo: Bool
        var inSplit: Bool
    }

    var hasSplit = false
    var splitCanGrow = false

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
        let items = store.tabs.map { tab in
            TabItem(id: tab.id, title: tab.title.isEmpty ? (tab.url?.host ?? "New Tab") : tab.title, url: tab.url,
                    favicon: tab.faviconURL, isLoading: tab.isLoading, progress: tab.progress, isPinned: tab.isPinned,
                    isYouTubeVideo: tab.youtubeVideoID != nil, inSplit: store.split?.tabIDs.contains(tab.id) ?? false)
        }
        hasSplit = store.split != nil
        splitCanGrow = store.split?.layout.grown != nil
        if items != tabs { tabs = items }
        if activeID != store.activeID { activeID = store.activeID }
        canGoBack = store.active?.webView.canGoBack ?? false
        canGoForward = store.active?.webView.canGoForward ?? false
        canReopenClosed = !store.recentlyClosed.isEmpty
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
        Haptics.perform(.generic)
    }

    func dismissCommandBar() {
        commandBar = nil
        controller?.focusActivePage()
    }

    // MARK: Tab actions (forwarded to the controller)

    func activate(_ id: UUID) { controller?.tabs.activate(id) }
    func close(_ id: UUID) { controller?.tabs.close(id) }
    func newTab() { presentCommandBar(newTab: true) }
    func reopenClosed() { _ = controller?.tabs.reopenClosed() }
    func goBack() { controller?.tabs.active?.goBack() }
    func goForward() { controller?.tabs.active?.goForward() }
    func reloadOrStop() {
        guard let tab = controller?.tabs.active else { return }
        if tab.isLoading { tab.stop() } else { tab.reload() }
    }
    func toggleSidebar() { controller?.toggleSidebar(nil) }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        controller?.tabs.setPinned(id, pinned)
        Haptics.perform(.levelChange)
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
        Haptics.perform(.alignment)
    }

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
        store.tabs.filter { $0.id != id && !$0.isPinned }.forEach { store.close($0.id) }
        Haptics.perform(.generic)
    }

    func closeBelow(_ id: UUID) {
        guard let store = controller?.tabs, let index = store.tabs.firstIndex(where: { $0.id == id }) else { return }
        store.tabs[(index + 1)...].filter { !$0.isPinned }.forEach { store.close($0.id) }
        Haptics.perform(.generic)
    }
}

/// Force Touch trackpad feedback for direct-manipulation moments (reordering, pinning, snapping).
enum Haptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
