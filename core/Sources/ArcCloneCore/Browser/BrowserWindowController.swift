import AppKit
import SwiftUI
import WebKit

/// One browser window: the SwiftUI sidebar on the left, the active tab's web view on the right,
/// and the command bar floating over both.
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    public let router = IPCRouter()
    public let tabs: TabStore
    let assistant: Assistant
    /// nil for private windows: they never record history.
    let history: History?
    let model: WindowModel
    var urlResolver: URLResolver { Preferences.urlResolver }
    let factory: WebViewFactory
    private var snapshotScheduled = false
    private var browsingActivity: NSUserActivity?
    private let splitController = NSSplitViewController()
    private let contentController = TabContentViewController()
    private var overlayHost: NSHostingView<CommandBarOverlay>?
    private let windowToolbar = WindowToolbar()
    private var commandBarObservation: Task<Void, Never>?
    var onClose: (@MainActor (BrowserWindowController) -> Void)?
    var onSessionChange: (@MainActor () -> Void)?

    /// Private windows use their own non-persistent data store, are never saved, and never feed the assistant.
    public let isPrivate: Bool

    public init(factory: WebViewFactory, assistant: Assistant, history: History?, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.history = isPrivate ? nil : history
        self.factory = factory
        self.assistant = assistant
        self.tabs = TabStore(factory: factory, router: router)
        self.model = WindowModel(isPrivate: isPrivate, assistant: AssistantChat(assistant: assistant))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Native unified toolbar: navigation over the sidebar, the page title over the content.
        // Web content starts below it, so no part of a page sits under the title bar.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbar = windowToolbar.toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 640, height: 420)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ArcCloneBrowserWindow")
        super.init(window: window)
        window.delegate = self
        model.controller = self
        model.assistant.window = self

        buildLayout()
        tabs.tabDelegate = self
        tabs.onChange = { [weak self] in self?.scheduleSnapshot() }
        tabs.onActiveChange = { [weak self] tab in self?.showTab(tab) }
        registerPageHandlers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        // A dark sidebar marks private windows at a glance.
        if isPrivate { effect.appearance = NSAppearance(named: .darkAqua) }
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        let sidebar = NSHostingView(rootView: SidebarView(window: model))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: effect.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let sidebarVC = NSViewController()
        sidebarVC.view = effect

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.titlebarSeparatorStyle = .none

        splitController.splitView.dividerStyle = .thin
        splitController.splitView.autosaveName = "ArcCloneSidebar"
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        if sidebarItem.viewController.view.frame.width < 1 { splitController.splitView.setPosition(280, ofDividerAt: 0) }

        // Root: the split view, with the command bar overlay above it (hidden while closed so it
        // never intercepts clicks).
        let root = RootViewController(content: splitController)
        let overlay = NSHostingView(rootView: CommandBarOverlay(window: model))
        overlay.isHidden = true
        root.addOverlay(overlay)
        overlayHost = overlay
        window?.contentViewController = root
        window?.setContentSize(NSSize(width: 1320, height: 860))
        observeCommandBar()
    }

    /// Shows the overlay host while the command bar is up, and hides it after the dismiss animation.
    private func observeCommandBar() {
        withObservationTracking { _ = model.commandBar } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.model.commandBar != nil {
                    self.overlayHost?.isHidden = false
                } else {
                    try? await Task.sleep(for: .milliseconds(280))
                    if self.model.commandBar == nil { self.overlayHost?.isHidden = true }
                }
                self.observeCommandBar()
            }
        }
    }

    public func showWindowCentered() {
        if window?.frameAutosaveName.isEmpty == false, !(window?.setFrameUsingName("ArcCloneBrowserWindow") ?? false) {
            window?.center()
        }
        showWindow(nil)
    }

    var isSidebarCollapsed: Bool { splitController.splitViewItems.first?.isCollapsed ?? false }

    // MARK: Tab display

    private func showTab(_ tab: Tab?) {
        contentController.display(tab?.webView)
        window?.makeFirstResponder(tab?.webView)
        model.selection = tab?.lastSelection
    }

    func focusActivePage() {
        if let web = tabs.active?.webView { window?.makeFirstResponder(web) }
    }

    /// Coalesces bursts of tab changes (progress ticks, KVO) into one UI update per runloop pass.
    func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.snapshotScheduled = false
            self.model.refresh(from: self.tabs)
            self.window?.title = self.tabs.active?.title ?? (self.isPrivate ? "Private" : "ArcClone")
            self.updateHandoff()
            self.onSessionChange?()
        }
    }

    func open(_ url: URL, newTab: Bool) {
        if newTab || tabs.active == nil {
            tabs.create(url: url)
        } else {
            tabs.active?.load(url)
        }
        focusActivePage()
    }

    // MARK: Handoff

    /// Advertises the active tab so it can be continued in Safari on another device.
    private func updateHandoff() {
        guard window?.isKeyWindow == true, !isPrivate else { return }
        guard let tab = tabs.active, let url = tab.url, url.scheme == "http" || url.scheme == "https" else {
            browsingActivity?.resignCurrent()
            return
        }
        let activity = browsingActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        browsingActivity = activity
        activity.webpageURL = url
        activity.title = tab.title
        activity.becomeCurrent()
    }

    // MARK: NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        updateHandoff()
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?(self) // owner persists the session while the tabs still exist
        browsingActivity?.invalidate()
        onClose = nil
        onSessionChange = nil
        commandBarObservation?.cancel()
        model.assistant.detach()
        tabs.tabs.forEach { assistant.context.ingest(tabID: $0.id, type: "tab.closed", payload: .null) }
        tabs.closeAll()
    }
}

// MARK: - TabDelegate

extension BrowserWindowController: TabDelegate {
    public func tabDidChange(_ tab: Tab) {
        scheduleSnapshot()
    }

    public func tab(_ tab: Tab, requestsNewTabWith request: URLRequest, inBackground: Bool) {
        guard let url = request.url else { return }
        tabs.create(url: url, activate: !inBackground)
    }

    public func tabRequestsClose(_ tab: Tab) {
        tabs.close(tab.id)
    }
}

/// Right-hand pane: holds the active tab's web view inside a rounded, inset card.
@MainActor
final class TabContentViewController: NSViewController {
    private let card = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")

    override func loadView() {
        let root = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            card.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    func display(_ webView: WKWebView?) {
        _ = view
        card.subviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = webView != nil
        card.isHidden = webView == nil
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            webView.topAnchor.constraint(equalTo: card.topAnchor),
            webView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }
}

/// The window's content: the sidebar/content split, with overlays (command bar) stacked above.
@MainActor
final class RootViewController: NSViewController {
    private let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        addChild(content)
        content.view.frame = root.bounds
        content.view.autoresizingMask = [.width, .height]
        root.addSubview(content.view)
        view = root
    }

    func addOverlay(_ overlay: NSView) {
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
    }
}
