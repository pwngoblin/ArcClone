import AppKit
import WebKit

/// One browser window: Svelte chrome in a sidebar, the active tab's web view on the right.
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    public let router = IPCRouter()
    public let tabs: TabStore
    public let chrome: ChromeHost
    let assistant: Assistant
    var urlResolver: URLResolver { Preferences.urlResolver }
    let factory: WebViewFactory
    var ownedRequests: Set<String> = []
    private var assistantListener: UUID?
    private var snapshotScheduled = false
    private var browsingActivity: NSUserActivity?
    private let splitController = NSSplitViewController()
    private let contentController = TabContentViewController()
    var onClose: (@MainActor (BrowserWindowController) -> Void)?
    var onSessionChange: (@MainActor () -> Void)?

    public init(factory: WebViewFactory, assistant: Assistant, paths: AppPaths) {
        self.factory = factory
        self.assistant = assistant
        self.tabs = TabStore(factory: factory, router: router)
        self.chrome = ChromeHost(uiRoot: paths.uiDist, router: router, inspectable: factory.inspectable)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 640, height: 420)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ArcCloneBrowserWindow")
        super.init(window: window)
        window.delegate = self

        buildLayout()
        tabs.tabDelegate = self
        tabs.onChange = { [weak self] in self?.scheduleSnapshot() }
        tabs.onActiveChange = { [weak self] tab in self?.showTab(tab) }
        chrome.onExternalLink = { [weak self] url in self?.tabs.create(url: url) }

        registerChromeHandlers()
        registerPageHandlers()
        registerAgentHandlers()
        assistantListener = assistant.addListener { [weak self] event in
            self?.handleAssistantEvent(event)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        let sidebarVC = NSViewController()
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        chrome.webView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(chrome.webView)
        NSLayoutConstraint.activate([
            chrome.webView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            chrome.webView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            chrome.webView.topAnchor.constraint(equalTo: effect.topAnchor),
            chrome.webView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        // WKWebView swallows mouse-downs, so give the titlebar row a native drag area
        // (leaving room on the right for the UI's navigation buttons).
        let drag = WindowDragView()
        drag.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(drag)
        NSLayoutConstraint.activate([
            drag.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 72),
            drag.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -128),
            drag.topAnchor.constraint(equalTo: effect.topAnchor),
            drag.heightAnchor.constraint(equalToConstant: 38),
        ])
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
        window?.contentViewController = splitController
        window?.setContentSize(NSSize(width: 1320, height: 860))
    }

    public func showWindowCentered() {
        if window?.frameAutosaveName.isEmpty == false, !(window?.setFrameUsingName("ArcCloneBrowserWindow") ?? false) {
            window?.center()
        }
        showWindow(nil)
    }

    // MARK: Tab display

    private func showTab(_ tab: Tab?) {
        contentController.display(tab?.webView)
        window?.makeFirstResponder(tab?.webView)
        if let tab { chrome.events.send("page.selection", ["tabId": .string(tab.id.uuidString), "text": JSONValue(tab.lastSelection)]) }
    }

    /// Coalesces bursts of tab changes (progress ticks, KVO) into one UI update per runloop pass.
    func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshotScheduled = false
                self.chrome.events.send("tabs.state", self.stateSnapshot)
                self.window?.title = self.tabs.active?.title ?? "ArcClone"
                self.updateHandoff()
                self.onSessionChange?()
            }
        }
    }

    var stateSnapshot: JSONValue {
        [
            "tabs": .array(tabs.tabs.map(\.snapshot)),
            "activeTabId": JSONValue(tabs.activeID?.uuidString),
            "canReopenClosed": .bool(!tabs.recentlyClosed.isEmpty),
        ]
    }

    func open(input: String, newTab: Bool) throws {
        guard let url = urlResolver.resolve(input) else { throw IPCError.invalidParams("Nothing to open") }
        if newTab || tabs.active == nil {
            tabs.create(url: url)
        } else {
            tabs.active?.load(url)
        }
        window?.makeFirstResponder(tabs.active?.webView)
    }

    // MARK: Handoff

    /// Advertises the active tab so it can be continued in Safari on another device.
    private func updateHandoff() {
        guard window?.isKeyWindow == true else { return }
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
        if let assistantListener { assistant.removeListener(assistantListener) }
        ownedRequests.forEach { assistant.cancel($0) }
        tabs.tabs.forEach { assistant.context.ingest(tabID: $0.id, type: "tab.closed", payload: .null) }
        tabs.closeAll()
        chrome.tearDown()
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
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
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

/// Transparent strip that moves the window and zooms on double-click, like a titlebar.
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
