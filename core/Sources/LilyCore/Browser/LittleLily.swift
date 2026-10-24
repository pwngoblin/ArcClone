import AppKit

/// Little Lily (docs/LITTLE_LILY.md): a small window for one page, where links from other apps
/// open. **Open in Lily** moves the page into the main window as it is (same web view: scroll
/// position, typed text and media keep going), and the small window closes.
extension BrowserWindowController {
    /// The host as people say it ("example.com", not "www.example.com"); the file name for files.
    static func siteName(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Little Lily never opens a second tab of its own: new tabs go to the main window.
    func openInMainWindow(_ url: URL?, activate: Bool) {
        guard let main = mainWindow?() else { return }
        if let url { main.tabs.create(url: url, activate: activate) }
        main.showWindow(nil)
        if url == nil { main.newTab(nil) }
    }

    /// File → Open in Lily (⇧⌘O) and the toolbar button.
    @objc public func openInLily(_ sender: Any?) {
        guard isLittle, let tab = tabs.active, let main = mainWindow?(), main !== self else { return }
        move(tab.id, to: main)
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        Haptics.step()
        window?.close()
    }

    /// Hands a live tab to another window: out of this store without tearing it down, into the
    /// other's current space with its routes. Extensions see it close here and open there; its web
    /// view moves panes, so the page isn't reloaded (unless that space has Separate logins, whose
    /// own cookies need a fresh load: `TabStore.adopt`).
    func move(_ id: UUID, to target: BrowserWindowController) {
        guard let tab = tabs.detach(id) else { return }
        target.tabs.adopt(tab)
    }
}
