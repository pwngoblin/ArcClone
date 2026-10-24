import AppKit
import WebKit

/// The tab's web view. Tidies WebKit's context menu: SF Symbol icons on every item, "New Tab"
/// instead of "New Window" (Lily opens new windows as tabs), and Open Link in Split View.
@MainActor
final class BrowserWebView: WKWebView {
    /// Called just before WebKit is asked to open the right-clicked link in a new window, so the
    /// tab can route that request into split view instead of a plain new tab.
    /// Where the next link opened from the context menu should go, set just before WebKit asks
    /// for a new window (`Tab.webView(_:createWebViewWith:…)`).
    enum LinkTarget { case split, little }
    var willOpenLink: ((LinkTarget) -> Void)?

    /// WebKit's menu item identifiers (stable strings) → our title (nil keeps WebKit's) and symbol.
    static let restyle: [String: (title: String?, symbol: String)] = [
        "WKMenuItemIdentifierOpenLink": ("Open Link", "arrow.up.right.square"),
        "WKMenuItemIdentifierOpenLinkInNewWindow": ("Open Link in New Tab", "plus.square.on.square"),
        "WKMenuItemIdentifierDownloadLinkedFile": ("Download Linked File", "arrow.down.circle"),
        "WKMenuItemIdentifierCopyLink": ("Copy Link", "link"),
        "WKMenuItemIdentifierOpenImageInNewWindow": ("Open Image in New Tab", "photo"),
        "WKMenuItemIdentifierDownloadImage": ("Download Image", "arrow.down.circle"),
        "WKMenuItemIdentifierCopyImage": ("Copy Image", "doc.on.doc"),
        "WKMenuItemIdentifierCopyImageURL": ("Copy Image Address", "link"),
        "WKMenuItemIdentifierOpenMediaInNewWindow": ("Open Video in New Tab", "play.rectangle"),
        "WKMenuItemIdentifierDownloadMedia": ("Download Video", "arrow.down.circle"),
        "WKMenuItemIdentifierCopyMediaLink": ("Copy Video Address", "link"),
        "WKMenuItemIdentifierToggleFullScreen": (nil, "arrow.up.left.and.arrow.down.right"),
        "WKMenuItemIdentifierToggleEnhancedFullScreen": (nil, "pip.enter"),
        "WKMenuItemIdentifierShowHideMediaControls": (nil, "slider.horizontal.below.rectangle"),
        "WKMenuItemIdentifierPlayPause": (nil, "playpause"),
        "WKMenuItemIdentifierMute": (nil, "speaker.slash"),
        "WKMenuItemIdentifierGoBack": (nil, "chevron.backward"),
        "WKMenuItemIdentifierGoForward": (nil, "chevron.forward"),
        "WKMenuItemIdentifierReload": (nil, "arrow.clockwise"),
        "WKMenuItemIdentifierCopy": (nil, "doc.on.doc"),
        "WKMenuItemIdentifierCut": (nil, "scissors"),
        "WKMenuItemIdentifierPaste": (nil, "doc.on.clipboard"),
        "WKMenuItemIdentifierLookUp": (nil, "character.book.closed"),
        "WKMenuItemIdentifierSearchWeb": (nil, "magnifyingglass"),
        "WKMenuItemIdentifierTranslate": (nil, "translate"),
        "WKMenuItemIdentifierShareMenu": (nil, "square.and.arrow.up"),
        "WKMenuItemIdentifierSpeechMenu": (nil, "waveform"),
        "WKMenuItemIdentifierSpellingMenu": (nil, "textformat.abc"),
        "WKMenuItemIdentifierInspectElement": (nil, "hammer"),
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        Self.restyle(menu)
        if let newTab = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }),
           let index = menu.items.firstIndex(of: newTab) {
            let split = NSMenuItem(title: "Open Link in Split View", action: #selector(openLinkInSplit(_:)), keyEquivalent: "")
            split.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            split.target = self
            split.representedObject = newTab
            menu.insertItem(split, at: index + 1)
            let little = NSMenuItem(title: "Open Link in Little Lily", action: #selector(openLinkInLittle(_:)), keyEquivalent: "")
            little.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            little.target = self
            little.representedObject = newTab
            menu.insertItem(little, at: index + 2)
        }
    }

    static func restyle(_ menu: NSMenu) {
        for item in menu.items {
            guard let id = item.identifier?.rawValue, let style = restyle[id] else { continue }
            if let title = style.title { item.title = title }
            if item.image == nil { item.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil) }
        }
    }

    /// WebKit keeps the right-clicked link to itself; its own "open in new window" item knows it.
    /// Mark where the next new-window request goes, then let that item run.
    @objc private func openLinkInSplit(_ sender: NSMenuItem) { openLink(sender, in: .split) }
    @objc private func openLinkInLittle(_ sender: NSMenuItem) { openLink(sender, in: .little) }

    private func openLink(_ sender: NSMenuItem, in target: LinkTarget) {
        guard let newTab = sender.representedObject as? NSMenuItem, let action = newTab.action else { return }
        willOpenLink?(target)
        NSApp.sendAction(action, to: newTab.target, from: newTab)
    }
}
