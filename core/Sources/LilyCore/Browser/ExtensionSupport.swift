import AppKit
import WebKit

// Bridges Lily's tabs and windows to the WebExtensions APIs (tabs.*, windows.*), and keeps the
// extension controller informed as tabs open, close, change and activate.

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {
    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { delegate as? BrowserWindowController }
    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        (delegate as? BrowserWindowController)?.tabs.tabs.firstIndex { $0 === self } ?? 0
    }
    /// nil for tabs that haven't been opened (restored, imported, asleep): asking about a tab must
    /// not create a web view, or extensions would undo tab virtualization.
    public func webView(for context: WKWebExtensionContext) -> WKWebView? { hasWebView ? webView : nil }
    public func size(for context: WKWebExtensionContext) -> CGSize { hasWebView ? webView.bounds.size : .zero }
    public func title(for context: WKWebExtensionContext) -> String? { title }
    public func url(for context: WKWebExtensionContext) -> URL? { url }
    public func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    public func zoomFactor(for context: WKWebExtensionContext) -> Double { hasWebView ? webView.pageZoom : 1 }
    public func isSelected(for context: WKWebExtensionContext) -> Bool {
        (delegate as? BrowserWindowController)?.tabs.activeID == id
    }

    public func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        (delegate as? BrowserWindowController)?.tabs.setPinned(id, pinned)
    }

    public func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        if selected { (delegate as? BrowserWindowController)?.tabs.activate(id) }
    }

    public func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        webView.pageZoom = min(3, max(0.3, zoomFactor))
    }

    public func activate(for context: WKWebExtensionContext) async throws {
        (delegate as? BrowserWindowController)?.tabs.activate(id)
    }

    public func close(for context: WKWebExtensionContext) async throws {
        (delegate as? BrowserWindowController)?.tabs.close(id)
    }

    public func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        // Extensions may only navigate to web pages, never to file: or other local schemes.
        guard url.scheme == "https" || url.scheme == "http" else { throw URLError(.unsupportedURL) }
        load(url)
    }

    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        // An unopened tab loads its address rather than reloading an empty web view.
        guard hasWebView else { if let url { load(url) }; return }
        if fromOrigin { webView.reloadFromOrigin() } else { reload() }
    }

    public func goBack(for context: WKWebExtensionContext) async throws { goBack() }
    public func goForward(for context: WKWebExtensionContext) async throws { goForward() }
}

@available(macOS 15.4, *)
extension BrowserWindowController: WKWebExtensionWindow {
    public func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs.tabs }
    public func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabs.active }
    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }
    public func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }
    public func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    public func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? NSScreen.main?.frame ?? .null }
    public func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        guard let window, frame.width >= 200, frame.height >= 200 else { return }
        window.setFrame(frame, display: true, animate: false)
    }
    public func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext) async throws {
        guard let window else { return }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .fullscreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .maximized: window.zoom(nil)
        default:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }
    public func focus(for context: WKWebExtensionContext) async throws { window?.makeKeyAndOrderFront(nil) }
    public func close(for context: WKWebExtensionContext) async throws { window?.performClose(nil) }
}

extension BrowserWindowController {
    /// The app's extension controller, for regular windows on macOS 15.4+.
    var extensionController: AnyObject? { factory.extensionController }

    /// Tells the extension controller about this window and its tabs (on creation, or when the
    /// first extension loads after windows already exist).
    func registerWithExtensions(_ controller: AnyObject) {
        guard #available(macOS 15.4, *), let controller = controller as? WKWebExtensionController, !isPrivate else { return }
        controller.didOpenWindow(self)
        tabs.tabs.forEach { controller.didOpenTab($0) }
        if window?.isKeyWindow == true { controller.didFocusWindow(self) }
    }

    func extensionsTabOpened(_ tab: Tab) {
        guard #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController else { return }
        controller.didOpenTab(tab)
    }

    func extensionsTabClosed(_ tab: Tab, windowIsClosing: Bool) {
        guard #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController else { return }
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    func extensionsTabActivated(_ tab: Tab?, previous: Tab?) {
        guard #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController, let tab else { return }
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func extensionsTabChanged(_ tab: Tab) {
        guard #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController else { return }
        controller.didChangeTabProperties([.title, .URL, .loading], for: tab)
    }

    func extensionsWindowFocused() {
        guard #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController else { return }
        controller.didFocusWindow(self)
    }

    func extensionsWindowClosed() {
        guard #available(macOS 15.4, *), let controller = extensionController as? WKWebExtensionController else { return }
        tabs.tabs.forEach { controller.didCloseTab($0, windowIsClosing: true) }
        controller.didCloseWindow(self)
    }

    /// An extension's popup, shown under the toolbar's Extensions button.
    func presentExtensionPopup(_ webView: WKWebView) {
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSViewController()
        host.view = webView
        host.preferredContentSize = NSSize(width: max(webView.frame.width, 320), height: max(webView.frame.height, 240))
        popover.contentViewController = host
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == WindowToolbar.extensions }) {
            popover.show(relativeTo: item)
        } else if let view = window?.contentView {
            popover.show(relativeTo: NSRect(x: view.bounds.maxX - 80, y: view.bounds.maxY - 10, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }
}
