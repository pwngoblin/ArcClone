import AppKit

/// Menu / keyboard actions. NSWindowController sits in the responder chain after its window,
/// so these are reached from MainMenu items with a nil target.
extension BrowserWindowController: NSMenuItemValidation {
    @objc public func newTab(_ sender: Any?) {
        if chrome.events.isReady {
            chrome.events.send("chrome.command", ["command": "newTab"])
            window?.makeFirstResponder(chrome.webView)
        } else {
            tabs.create(url: nil)
        }
    }

    @objc public func closeTab(_ sender: Any?) {
        if let id = tabs.activeID { tabs.close(id) } else { window?.performClose(sender) }
    }

    @objc public func reopenClosedTab(_ sender: Any?) {
        tabs.reopenClosed()
    }

    @objc public func focusAddressBar(_ sender: Any?) {
        window?.makeFirstResponder(chrome.webView)
        chrome.events.send("chrome.command", ["command": "focusAddressBar"])
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
        chrome.events.send("chrome.command", ["command": "toggleAssistant"])
        window?.makeFirstResponder(chrome.webView)
    }

    @objc public func summarizePage(_ sender: Any?) {
        chrome.events.send("chrome.command", ["command": "summarize"])
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        chrome.events.send("chrome.toast", ["message": "Link copied"])
    }

    @objc public func printPage(_ sender: Any?) {
        guard let web = tabs.active?.webView, let window else { return }
        let operation = web.printOperation(with: .shared)
        operation.view?.frame = web.bounds // WebKit prints blank pages without a frame
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc public func zoomIn(_ sender: Any?) { adjustZoom(by: 0.1) }
    @objc public func zoomOut(_ sender: Any?) { adjustZoom(by: -0.1) }
    @objc public func actualSize(_ sender: Any?) { tabs.active?.webView.pageZoom = 1 }

    private func adjustZoom(by delta: CGFloat) {
        guard let web = tabs.active?.webView else { return }
        web.pageZoom = min(3, max(0.3, web.pageZoom + delta))
    }

    @objc public func reloadChromeUI(_ sender: Any?) { chrome.reload() }

    @objc public func reloadInjections(_ sender: Any?) {
        do {
            try factory.registry.reload()
            for tab in tabs.tabs { factory.registry.install(into: tab.webView.configuration.userContentController) }
            tabs.active?.reload()
            chrome.events.send("chrome.toast", ["message": "Injections reloaded"])
        } catch {
            chrome.events.send("chrome.toast", ["message": .string("Injection reload failed: \(error)")])
        }
    }

    @objc public func restartAgentBridge(_ sender: Any?) { agent.restart() }

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
        case #selector(selectTabByNumber(_:)): return item.tag == 9 ? !tabs.tabs.isEmpty : tabs.tabs.count >= item.tag
        default: return true
        }
    }
}
