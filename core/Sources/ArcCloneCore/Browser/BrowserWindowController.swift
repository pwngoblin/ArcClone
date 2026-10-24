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
    /// Long-field drafts (FormDrafts); nil in private windows, so nothing typed there is kept.
    var formDrafts: FormDrafts?
    /// The page each tab was last offered a restore for, so a page that updates its title
    /// (page.didChange) is asked once, not on every change.
    var formRestoreOffered: [UUID: String] = [:]
    /// Link Scrolling: panes it's on in, and per target pane the position waiting to be applied
    /// while the previous one is still in flight (so fast scrolling never queues up calls).
    var scrollLinkedTabs: Set<UUID> = []
    var scrollApplying: Set<UUID> = []
    var scrollPending: [UUID: JSONValue] = [:]
    /// Searched by the command bar (read-only, also in private windows).
    weak var bookmarks: Bookmarks?
    let model: WindowModel
    var urlResolver: URLResolver { Preferences.urlResolver }
    let factory: WebViewFactory
    private var snapshotScheduled = false
    private var browsingActivity: NSUserActivity?
    private let splitController = NSSplitViewController()
    let contentController = TabContentViewController()
    /// Find in page (⌘F, ⌘G, ⇧⌘G), for the active tab (FindInPage.swift).
    lazy var find = FindModel(controller: self)
    /// The next check for split panes to pause (PaneFreezer); one wake-up, never polling.
    var freezeTask: Task<Void, Never>?
    private var overlayHost: NSHostingView<CommandBarOverlay>?
    private let windowToolbar = WindowToolbar()
    private weak var sidebarHost: NSView?
    private var swipeMonitor: Any?
    private var sleeper: TabSleeper?
    private var swipeDelta = CGSize.zero
    private var swipeAxis: SwipeAxis = .idle
    private var swipeCrossed = false
    private var swallowMomentum = false
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
        // macOS window restoration would save titles (page titles) unencrypted under Saved
        // Application State; ArcClone restores its own sessions, encrypted, instead.
        window.isRestorable = false
        if isPrivate {
            // Keep private windows out of screenshots, screen recording and screen sharing by other
            // apps, as far as macOS honors the request.
            window.sharingType = .none
        }
        super.init(window: window)
        window.delegate = self
        model.controller = self
        model.assistant.window = self

        buildLayout()
        tabs.tabDelegate = self
        tabs.onChange = { [weak self] in self?.scheduleSnapshot() }
        tabs.onActiveChange = { [weak self] tab in self?.showTab(tab) }
        tabs.onSplitChange = { [weak self] in
            self?.showTab(self?.tabs.active)
            self?.updateScrollLinks()
        }
        tabs.onSpaceChange = { [weak self] forward in self?.model.spaceForward = forward }
        tabs.onTabAdded = { [weak self] tab in self?.extensionsTabOpened(tab); self?.sleeper?.reschedule() }
        tabs.onTabRemoved = { [weak self] tab in self?.extensionsTabClosed(tab, windowIsClosing: false); self?.sleeper?.reschedule() }
        tabs.onActiveTabSwitched = { [weak self] new, previous in
            self?.extensionsTabActivated(new, previous: previous)
            self?.sleeper?.reschedule()
        }
        contentController.onFocus = { [weak self] id in self?.tabs.activate(id) }
        // Scrolling a paused pane is using it: its idle time starts again.
        contentController.onResume = { [weak self] id in
            self?.tabs.tab(id)?.markActivated()
            self?.scheduleFreeze()
        }
        registerPageHandlers()
        if !isPrivate { installSpaceSwipe() }
        sleeper = TabSleeper(store: tabs)
        if let extensionController { registerWithExtensions(extensionController) }
    }

    /// Two-finger horizontal swipes over the sidebar switch spaces. Events of a swipe are consumed so
    /// the tab list doesn't scroll at the same time.
    private func installSpaceSwipe() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleSwipe(event) ?? false }
            return consumed ? nil : event
        }
    }

    private enum SwipeAxis { case idle, undecided, horizontal, vertical }

    /// Interactive space swipe: the tab list follows the fingers; past the threshold it switches,
    /// otherwise it springs back. Returns true when the event belongs to the swipe.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.window === window, event.hasPreciseScrollingDeltas else { return false }
        // Momentum after a swipe ends must not scroll the (new) list or trigger another switch.
        if !event.momentumPhase.isEmpty {
            let swallow = swallowMomentum
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swallowMomentum = false }
            return swallow
        }
        switch event.phase {
        case .mayBegin, .began:
            swallowMomentum = false
            guard model.panel == .tabs, tabs.spaces.count > 1, let host = sidebarHost,
                  host.bounds.contains(host.convert(event.locationInWindow, from: nil)) else { swipeAxis = .idle; return false }
            swipeAxis = .undecided
            swipeDelta = .zero
            swipeCrossed = false
            return false
        case .changed:
            // Finger direction, whatever the natural-scrolling setting.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            switch swipeAxis {
            case .idle, .vertical:
                return false
            case .undecided:
                swipeDelta.width += dx
                swipeDelta.height += abs(event.scrollingDeltaY)
                if abs(swipeDelta.width) > 6, abs(swipeDelta.width) > swipeDelta.height * 1.4 {
                    swipeAxis = .horizontal
                    updateSwipe()
                    return true
                }
                if swipeDelta.height > 6 { swipeAxis = .vertical }
                return false
            case .horizontal:
                swipeDelta.width += dx
                updateSwipe()
                return true
            }
        case .ended, .cancelled:
            defer { swipeAxis = .idle }
            guard swipeAxis == .horizontal else { return false }
            swallowMomentum = true
            finishSwipe(cancelled: event.phase == .cancelled)
            return true
        default:
            return swipeAxis == .horizontal
        }
    }

    private var swipeThreshold: CGFloat { max(60, (sidebarHost?.bounds.width ?? 260) * 0.25) }

    /// Index offset the current drag points at (+1 next, -1 previous), if that space exists.
    private func swipeTarget(for offset: CGFloat) -> Int? {
        guard let index = tabs.spaces.firstIndex(where: { $0.id == tabs.currentSpaceID }) else { return nil }
        let step = offset < 0 ? 1 : -1
        return tabs.spaces.indices.contains(index + step) ? step : nil
    }

    private func updateSwipe() {
        let raw = swipeDelta.width
        // Rubber-band when there's no space in that direction.
        let offset = swipeTarget(for: raw) == nil ? raw * 0.2 : raw
        model.spaceDragOffset = offset
        // Arms past the threshold, disarms only well below it, so finger jitter at the edge doesn't
        // flip it back and forth. One tick when it arms is the swipe's only haptic.
        let armed = swipeTarget(for: raw) != nil && abs(offset) >= (swipeCrossed ? swipeThreshold * 0.7 : swipeThreshold)
        if armed && !swipeCrossed { Haptics.snap() }
        swipeCrossed = armed
    }

    private func finishSwipe(cancelled: Bool) {
        let offset = swipeDelta.width
        swipeDelta = .zero
        if !cancelled, swipeCrossed, let step = swipeTarget(for: offset) {
            // One animated update: the new space and the offset returning to 0 land together, so the
            // old list keeps moving from where the fingers left it instead of jumping back first.
            // (The sidebar model normally refreshes a run-loop turn later; here it must not.)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                tabs.switchSpace(by: step)
                model.refresh(from: tabs)
                model.spaceDragOffset = 0
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.spaceDragOffset = 0 }
        }
        swipeCrossed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private let animationOverlay = AnimationOverlayView()

    /// Why the download flight won't play right now, or nil when it will. It's skipped on purpose
    /// with Reduce Motion on or the sidebar (and its downloads button) hidden.
    var downloadFlightSkipReason: String? {
        if window?.contentView == nil || sidebarHost == nil { return "no window" }
        if isSidebarCollapsed { return "sidebar collapsed" }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return "reduce motion" }
        return nil
    }

    private func buildLayout() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        // A dark sidebar marks private windows at a glance.
        if isPrivate { effect.appearance = NSAppearance(named: .darkAqua) }
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        let sidebar = NSHostingView(rootView: SidebarView(window: model))
        sidebarHost = sidebar
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

    /// Memory pressure: sleep every background tab that can sleep.
    func sleepBackgroundTabs() {
        Task { await sleeper?.sweep(force: true) }
    }

    private func showTab(_ tab: Tab?) {
        // Every pane of a visible split must be awake.
        if let tab, let split = tabs.split, split.tabIDs.contains(tab.id) { split.tabIDs.compactMap(tabs.tab).forEach { $0.wake() } }
        contentController.display(active: tab, split: tabs.split) { [tabs] in tabs.tab($0) }
        scheduleFreeze()
        find.activeTabChanged()
        window?.makeFirstResponder(tab?.webView)
        model.selection = tab?.lastSelection
    }

    /// Edit → Find…, Find Next, Find Previous; the item's tag is the NSTextFinder.Action.
    override public func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag else { return }
        find.perform(NSTextFinder.Action(rawValue: tag))
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
        extensionsWindowFocused()
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?(self) // owner persists the session while the tabs still exist
        extensionsWindowClosed()
        tabs.onTabRemoved = nil
        browsingActivity?.invalidate()
        onClose = nil
        onSessionChange = nil
        commandBarObservation?.cancel()
        sleeper?.stop()
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        contentController.tearDown()

        model.assistant.detach()
        tabs.tabs.forEach { assistant.context.ingest(tabID: $0.id, type: "tab.closed", payload: .null) }
        tabs.closeAll()
    }
}

// MARK: - TabDelegate

extension BrowserWindowController: TabDelegate {
    public func tabDidChange(_ tab: Tab) {
        scheduleSnapshot()
        extensionsTabChanged(tab)
    }

    public func tab(_ tab: Tab, requestsNewTabWith request: URLRequest, inBackground: Bool) {
        guard let url = request.url else { return }
        tabs.create(url: url, activate: !inBackground)
    }

    /// The link opens beside the tab it came from: added to that tab's split if it has room,
    /// otherwise the two start a new split.
    public func tab(_ tab: Tab, requestsSplitWith request: URLRequest) {
        guard let url = request.url else { return }
        tabs.activate(tab.id)
        let opened = tabs.create(url: url, activate: false)
        if let split = tabs.split, split.layout.grown != nil {
            tabs.addToSplit(opened.id)
        } else if tabs.split == nil {
            tabs.makeSplit(.twoColumns, with: [opened.id])
        } else {
            tabs.activate(opened.id) // the split is full (four panes): open it as a tab
        }
        Haptics.step()
    }

    public func tabRequestsClose(_ tab: Tab) {
        tabs.close(tab.id)
    }

    public func tabDidStartDownload(_ tab: Tab) {
        animateDownloadFlight()
        Haptics.step()
    }

    /// A file icon arcs from the page into the sidebar's downloads button, shrinking as it lands.
    /// It's drawn in a click-through overlay kept above every other view (web content, the command
    /// bar), since a bare layer on the root can end up underneath them.
    func animateDownloadFlight() {
        guard downloadFlightSkipReason == nil, let root = window?.contentView, let host = sidebarHost else { return }
        let overlay = animationOverlay
        if root.subviews.last !== overlay {
            overlay.frame = root.bounds
            overlay.autoresizingMask = [.width, .height]
            root.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        // The button reports its frame in the sidebar's top-left-origin space; before it has, aim
        // at the footer where it sits.
        var frame = model.downloadsButtonFrame
        if frame == .zero { frame = CGRect(x: 30, y: host.bounds.height - 30, width: 30, height: 28) }
        let target = NSPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY)
        let end = host.convert(target, to: overlay)
        let content = contentController.view
        let start = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: overlay)
        let scale = window?.backingScaleFactor ?? 2

        let size: CGFloat = 44
        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        icon.position = end
        let symbol = NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .semibold).applying(.init(paletteColors: [
                NSColor(hex: UserDefaults.standard.string(forKey: AppearanceStyle.Key.accent) ?? AppearanceStyle.defaultAccent)])))
        icon.contentsScale = scale
        icon.contents = symbol?.layerContents(forContentsScale: scale)
        icon.contentsGravity = .resizeAspect
        icon.shadowOpacity = 0.25
        icon.shadowRadius = 8
        icon.shadowOffset = CGSize(width: 0, height: -3)
        overlay.layer?.addSublayer(icon)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 160))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.6
        shrink.toValue = 0.35
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.85, 1]
        let group = CAAnimationGroup()
        group.animations = [move, shrink, fade]
        group.duration = 0.75
        CATransaction.begin()
        CATransaction.setCompletionBlock { icon.removeFromSuperlayer() }
        icon.opacity = 0
        icon.add(group, forKey: "flight")
        CATransaction.commit()
    }
}

/// A transparent layer above the whole window for short decorative animations; clicks pass through.
final class AnimationOverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
