import AppKit
import SwiftUI

/// Menu / keyboard actions. NSWindowController sits in the responder chain after its window,
/// so these are reached from MainMenu items with a nil target.
extension BrowserWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(toggleSiteDarkMode(_:)):
            let mode = factory.siteSettings?.darkMode(for: tabs.active?.webView.url) ?? .standard
            item.image = NSImage(systemSymbolName: mode == .standard || mode == .light ? "moon" : "moon.fill", accessibilityDescription: item.label)
            return SiteSettings.key(for: tabs.active?.webView.url) != nil
        case #selector(toggleSiteAdBlocking(_:)):
            let blocking = (factory.adBlocker?.isEnabled ?? false) && !(factory.siteSettings?.adsAllowed(for: tabs.active?.webView.url) ?? false)
            item.image = NSImage(systemSymbolName: blocking ? "shield.lefthalf.filled" : "shield.slash", accessibilityDescription: item.label)
            item.toolTip = blocking ? "Blocking ads on this site. Click to allow." : "Ads allowed on this site. Click to block."
            return factory.adBlocker?.isEnabled == true && SiteSettings.key(for: tabs.active?.webView.url) != nil
        case #selector(showSiteSettings(_:)):
            return SiteSettings.key(for: tabs.active?.webView.url) != nil
        case #selector(goBack(_:)): return tabs.active?.webView.canGoBack ?? false
        case #selector(goForward(_:)): return tabs.active?.webView.canGoForward ?? false
        case #selector(reloadPage(_:)): return tabs.active != nil
        default: return true
        }
    }

    @objc public func newTab(_ sender: Any?) {
        model.presentCommandBar(newTab: true)
    }

    @objc public func closeTab(_ sender: Any?) {
        if let id = tabs.activeID { tabs.close(id) } else { window?.performClose(sender) }
    }

    @objc public func reopenClosedTab(_ sender: Any?) {
        tabs.reopenClosed()
    }

    @objc public func focusAddressBar(_ sender: Any?) {
        model.presentCommandBar(newTab: false)
    }

    @objc public func showCommandPalette(_ sender: Any?) {
        model.presentCommandPalette()
    }

    /// History → Restore Typed Text: puts drafts for this page back into its empty fields.
    @objc public func restoreTypedText(_ sender: Any?) {
        guard let drafts = formDrafts, let tab = tabs.active, let url = tab.url else { return }
        let saved = drafts.drafts(for: url)
        guard !saved.isEmpty else { return }
        let args: JSONValue = ["drafts": .array(saved.map { ["field": .string($0.field), "text": .string($0.text)] })]
        Task { [weak self] in
            let restored = (try? await tab.callInjection("form.restore", args))?["restored"]?.int ?? 0
            self?.model.showToast(restored > 0 ? "Restored the text you typed" : "Nothing restored: those fields already have text")
        }
    }

    /// A page with saved drafts loaded in the active tab: offer them back, once per page.
    func offerFormRestore(_ tab: Tab) {
        guard let drafts = formDrafts, tab.id == tabs.activeID, let url = tab.url, let page = FormDrafts.pageKey(url),
              formRestoreOffered[tab.id] != page, !drafts.drafts(for: url).isEmpty else { return }
        formRestoreOffered[tab.id] = page
        Task { [weak self] in
            // Only where there's a field to put it back into.
            guard (try? await tab.callInjection("form.fields"))?["count"]?.int ?? 0 > 0 else { return }
            self?.model.showToast("You typed text on this page earlier", action: "Restore") { self?.restoreTypedText(nil) }
        }
    }

    @objc public func reloadPage(_ sender: Any?) { tabs.active?.reload() }
    @objc public func hardReloadPage(_ sender: Any?) { tabs.active?.webView.reloadFromOrigin() }
    @objc public func goBack(_ sender: Any?) { tabs.active?.goBack() }
    @objc public func goForward(_ sender: Any?) { tabs.active?.goForward() }

    @objc public func toggleSidebar(_ sender: Any?) {
        (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(sender)
    }

    @objc public func toggleAssistant(_ sender: Any?) {
        if let split = window?.contentViewController as? NSSplitViewController, split.splitViewItems.first?.isCollapsed == true {
            split.toggleSidebar(sender)
        }
        model.showsAssistant.toggle()
    }

    @objc public func summarizePage(_ sender: Any?) {
        if isSidebarCollapsed { toggleSidebar(sender) }
        model.showsAssistant = true
        model.assistant.summarize()
    }

    @objc public func selectTabByNumber(_ sender: NSMenuItem) {
        // ⌘9 always means the last tab, as in other browsers.
        if sender.tag == 9 { tabs.activateLast() } else { tabs.activate(index: sender.tag - 1) }
    }

    @objc public func selectNextTab(_ sender: Any?) { tabs.cycle(by: 1) }
    @objc public func selectPreviousTab(_ sender: Any?) { tabs.cycle(by: -1) }

    @objc public func togglePinTab(_ sender: Any?) {
        guard let tab = tabs.active else { return }
        tabs.setPinned(tab.id, !tab.isPinned)
    }

    @objc public func copyPageURL(_ sender: Any?) {
        guard let url = tabs.active?.url else { return }
        Clipboard.copy(url.absoluteString, sensitive: isPrivate)
        model.showToast("Link copied")
    }

    @objc public func printPage(_ sender: Any?) {
        guard let web = tabs.active?.webView, let window else { return }
        let operation = web.printOperation(with: .shared)
        operation.view?.frame = web.bounds // WebKit prints blank pages without a frame
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc public func zoomIn(_ sender: Any?) { adjustZoom(by: 0.1) }
    @objc public func zoomOut(_ sender: Any?) { adjustZoom(by: -0.1) }
    @objc public func actualSize(_ sender: Any?) { setZoom(SiteSettings.defaultZoom) }

    private func adjustZoom(by delta: CGFloat) {
        guard let web = tabs.active?.webView else { return }
        let next = Double(min(3, max(0.3, web.pageZoom + delta)))
        if next == 3 || next == 0.3 { Haptics.snap() } // hit a limit
        setZoom((next * 100).rounded() / 100)
    }

    /// Applies a zoom level and remembers it for the site (except in private windows).
    func setZoom(_ zoom: Double) {
        guard let tab = tabs.active else { return }
        tab.webView.pageZoom = zoom
        if factory.savesSiteChanges, let settings = factory.siteSettings {
            settings.update(tab.webView.url) { $0.zoom = abs(zoom - SiteSettings.defaultZoom) < 0.001 ? nil : zoom }
        }
        model.showToast("Zoom \(Int((zoom * 100).rounded()))%")
        Haptics.snap()
    }

    // MARK: Split view

    /// View → Split View → <layout>; the layout travels in the item's representedObject.
    @objc public func splitView(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let layout = SplitLayout(rawValue: raw) else { return }
        if tabs.active == nil { tabs.create(url: nil) }
        tabs.makeSplit(layout)
    }

    @objc public func nextSpace(_ sender: Any?) { model.switchSpace(by: 1) }
    @objc public func previousSpace(_ sender: Any?) { model.switchSpace(by: -1) }

    @objc public func exitSplitView(_ sender: Any?) {
        tabs.exitSplit()
        Haptics.tap()
    }

    /// View → Split View → Link Scrolling.
    @objc public func toggleLinkScrolling(_ sender: Any?) {
        guard let split = tabs.split else { return }
        tabs.setScrollLinked(!split.scrollLinked)
        model.showToast(split.scrollLinked ? "Scrolling unlinked" : "Scrolling linked")
    }

    /// Turns Link Scrolling on in the panes of linked splits and off where it no longer applies.
    func updateScrollLinks() {
        let wanted = Set(tabs.splits.filter(\.scrollLinked).flatMap(\.tabIDs))
        for id in wanted.symmetricDifference(scrollLinkedTabs) {
            if let tab = tabs.tab(id) { setScrollLink(wanted.contains(id), in: tab) }
        }
        scrollLinkedTabs = wanted
        scrollPending = scrollPending.filter { wanted.contains($0.key) }
    }

    func setScrollLink(_ on: Bool, in tab: Tab) {
        guard tab.hasWebView else { return } // an unloaded pane links when its page loads
        Task { _ = try? await tab.callInjection("scroll.link", ["on": .bool(on)], timeout: 5) }
    }

    /// One call in flight per pane; a newer position replaces any still waiting.
    func applyScroll(_ position: JSONValue, to id: UUID) {
        guard scrollLinkedTabs.contains(id), let tab = tabs.tab(id), tab.hasWebView else { return }
        guard !scrollApplying.contains(id) else {
            scrollPending[id] = position
            return
        }
        scrollApplying.insert(id)
        Task { [weak self] in
            _ = try? await tab.callInjection("scroll.apply", position, timeout: 2)
            guard let self else { return }
            self.scrollApplying.remove(id)
            if let next = self.scrollPending.removeValue(forKey: id) { self.applyScroll(next, to: id) }
        }
    }

    /// The Split View submenu, shared by the View menu and the toolbar.
    static func splitMenu() -> NSMenu {
        let menu = NSMenu(title: "Split View")
        for (index, layout) in SplitLayout.allCases.enumerated() {
            let item = NSMenuItem(title: layout.title, action: #selector(splitView(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.command, .control]
            item.representedObject = layout.rawValue
            item.image = NSImage(systemSymbolName: layout.symbol, accessibilityDescription: layout.title)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let link = NSMenuItem(title: "Link Scrolling", action: #selector(toggleLinkScrolling(_:)), keyEquivalent: "l")
        link.keyEquivalentModifierMask = [.command, .control]
        link.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Link Scrolling")
        menu.addItem(link)
        let exit = NSMenuItem(title: "Exit Split View", action: #selector(exitSplitView(_:)), keyEquivalent: "0")
        exit.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(exit)
        return menu
    }

    /// Toolbar → Extensions: run an extension, add one, or manage them.
    @objc public func showExtensions(_ sender: Any?) {
        let popover = NSPopover()
        popover.behavior = .transient
        let content: AnyView
        if let delegate = NSApp.delegate as? AppDelegate, let library = delegate.extensionLibrary, !isPrivate {
            content = AnyView(ExtensionToolbarView(library: library, runtime: delegate.extensionRuntime) { [weak popover] in popover?.performClose(nil) })
        } else {
            content = AnyView(Label("Extensions don't run in private windows", systemImage: "puzzlepiece.extension").padding(16))
        }
        popover.contentViewController = NSHostingController(rootView: content.appAccent())
        if let item = sender as? NSToolbarItem {
            popover.show(relativeTo: item)
        } else if let view = window?.contentView {
            popover.show(relativeTo: NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 10, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }

    /// Toolbar → Site Settings: a popover for the current site.
    @objc public func showSiteSettings(_ sender: Any?) {
        guard let settings = factory.siteSettings, let url = tabs.active?.webView.url, SiteSettings.key(for: url) != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SiteSettingsView(settings: settings, url: url, isPrivate: isPrivate, controller: self))
        if let item = sender as? NSToolbarItem {
            popover.show(relativeTo: item)
        } else if let view = window?.contentView {
            popover.show(relativeTo: NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 10, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }

    /// Allow or block ads on the current site, then reload so the change takes effect.
    @objc public func toggleSiteAdBlocking(_ sender: Any?) {
        guard let tab = tabs.active, let settings = factory.siteSettings, factory.savesSiteChanges else {
            model.showToast("Site changes aren't saved in private windows")
            return
        }
        let allow = !settings.adsAllowed(for: tab.webView.url)
        settings.update(tab.webView.url) { $0.adsAllowed = allow ? true : nil }
        tab.reload()
        model.showToast(allow ? "Ads allowed on this site" : "Blocking ads on this site")
        Haptics.tap()
    }

    @objc public func toggleSiteDarkMode(_ sender: Any?) {
        guard let tab = tabs.active, let settings = factory.siteSettings else { return }
        let next: SiteSettings.DarkMode = settings.darkMode(for: tab.webView.url) == .standard ? .forced : .standard
        setDarkMode(next)
    }

    func setDarkMode(_ mode: SiteSettings.DarkMode) {
        guard let tab = tabs.active, let settings = factory.siteSettings else { return }
        if factory.savesSiteChanges {
            settings.update(tab.webView.url) { $0.darkMode = mode == SiteSettings.defaultDarkMode ? nil : mode }
            tabs.tabs.filter { SiteSettings.key(for: $0.url) == SiteSettings.key(for: tab.webView.url) }.forEach { $0.siteSettingsDidChange() }
        } else {
            tab.webView.appearance = mode == .standard ? nil : NSAppearance(named: mode == .light ? .aqua : .darkAqua)
            Task { _ = try? await tab.callInjection("darkMode.apply", ["mode": .string(mode.rawValue)], timeout: 5) }
        }
        model.showToast("Appearance: \(mode.title)")
        Haptics.step()
    }


    /// Develop → Show Web Inspector (⌥⌘I), for the active tab.
    @objc public func showWebInspector(_ sender: Any?) {
        if let web = tabs.active?.webView { WebInspector.show(for: web) }
    }

    /// Web developer features switched: every open page follows.
    func applyWebInspector() {
        tabs.tabs.filter(\.hasWebView).forEach { WebInspector.apply(to: $0.webView) }
    }

    @objc public func reloadInjections(_ sender: Any?) {
        do {
            try factory.registry.reload()
            for tab in tabs.tabs where tab.hasWebView { factory.registry.install(into: tab.webView.configuration.userContentController) }
            tabs.active?.reload()
            model.showToast("Injections reloaded")
        } catch {
            model.showToast("Injection reload failed: \(Sanitize.errorMessage(error))")
        }
    }

    @objc public func reloadAssistant(_ sender: Any?) { assistant.reconfigure(.fromPreferences()) }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return tabs.active?.webView.canGoBack ?? false
        case #selector(goForward(_:)): return tabs.active?.webView.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !tabs.recentlyClosed.isEmpty
        case #selector(reloadPage(_:)), #selector(hardReloadPage(_:)), #selector(copyPageURL(_:)), #selector(printPage(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)), #selector(summarizePage(_:)):
            return tabs.active != nil
        case #selector(togglePinTab(_:)):
            item.title = tabs.active?.isPinned == true ? "Unpin Tab" : "Pin Tab"
            return tabs.active != nil
        case #selector(exitSplitView(_:)): return tabs.split != nil
        case #selector(showWebInspector(_:)): return WebInspector.canShow(for: tabs.active.flatMap { $0.hasWebView ? $0.webView : nil })
        case #selector(performTextFinderAction(_:)):
            return find.canPerform(NSTextFinder.Action(rawValue: item.tag))
        case #selector(toggleLinkScrolling(_:)):
            item.state = tabs.split?.scrollLinked == true ? .on : .off
            return tabs.split != nil
        case #selector(restoreTypedText(_:)):
            return tabs.active?.url.map { formDrafts?.drafts(for: $0).isEmpty == false } ?? false
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)): return tabs.spaces.count > 1
        case #selector(splitView(_:)):
            item.state = (item.representedObject as? String) == tabs.split?.layout.rawValue ? .on : .off
            return true
        case #selector(selectTabByNumber(_:)): return item.tag == 9 ? !tabs.tabs.isEmpty : tabs.tabs.count >= item.tag
        default: return true
        }
    }
}
