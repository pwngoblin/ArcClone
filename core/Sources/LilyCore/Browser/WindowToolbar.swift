import AppKit

/// The window's native toolbar, Safari/Notes style: sidebar toggle and navigation over the sidebar,
/// the page title and page controls over the content, split by a separator that follows the divider.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    static let back = NSToolbarItem.Identifier("Lily.back")
    static let forward = NSToolbarItem.Identifier("Lily.forward")
    static let reload = NSToolbarItem.Identifier("Lily.reload")
    static let newTab = NSToolbarItem.Identifier("Lily.newTab")
    static let siteSettings = NSToolbarItem.Identifier("Lily.siteSettings")
    static let darkMode = NSToolbarItem.Identifier("Lily.darkMode")
    static let split = NSToolbarItem.Identifier("Lily.split")
    static let adBlock = NSToolbarItem.Identifier("Lily.adBlock")
    static let extensions = NSToolbarItem.Identifier("Lily.extensions")
    static let copyLink = NSToolbarItem.Identifier("Lily.copyLink")
    static let openInLily = NSToolbarItem.Identifier("Lily.openInLily")

    let toolbar: NSToolbar
    private let style: BrowserWindowController.Style

    init(style: BrowserWindowController.Style = .regular) {
        self.style = style
        toolbar = NSToolbar(identifier: style == .little ? "LilyLittleToolbar" : "LilyBrowserToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Little Lily: page navigation, then what you do with a page you only came to look at.
        if style == .little { return [Self.back, Self.forward, Self.reload, .flexibleSpace, Self.copyLink, Self.openInLily] }
        // Navigation sits at the start of the content side: over the sidebar, the traffic lights
        // plus four buttons overflowed narrow sidebars and pushed Reload into the » menu.
        return [.toggleSidebar, .sidebarTrackingSeparator, Self.back, Self.forward, Self.reload, .flexibleSpace,
         Self.split, Self.extensions, Self.adBlock, Self.darkMode, Self.siteSettings, Self.newTab]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.back: return button(id, "Back", "chevron.left", #selector(BrowserWindowController.goBack(_:)))
        case Self.forward: return button(id, "Forward", "chevron.right", #selector(BrowserWindowController.goForward(_:)))
        case Self.reload: return button(id, "Reload", "arrow.clockwise", #selector(BrowserWindowController.reloadPage(_:)))
        case Self.newTab: return button(id, "New Tab", "plus", #selector(BrowserWindowController.newTab(_:)))
        case Self.split:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Split View"
            item.toolTip = "Split View"
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split View")
            item.menu = BrowserWindowController.splitMenu()
            item.showsIndicator = true
            return item
        case Self.extensions:
            // A plain button opening a popover: a menu toolbar item whose menu is filled lazily can
            // show nothing when clicked.
            return button(id, "Extensions", "puzzlepiece.extension", #selector(BrowserWindowController.showExtensions(_:)))
        case Self.adBlock: return button(id, "Block Ads on This Site", "shield.lefthalf.filled", #selector(BrowserWindowController.toggleSiteAdBlocking(_:)))
        case Self.darkMode: return button(id, "Dark Mode for This Site", "moon", #selector(BrowserWindowController.toggleSiteDarkMode(_:)))
        case Self.siteSettings: return button(id, "Site Settings", "slider.horizontal.3", #selector(BrowserWindowController.showSiteSettings(_:)))
        case Self.copyLink: return button(id, "Copy Link", "link", #selector(BrowserWindowController.copyPageURL(_:)))
        case Self.openInLily: return button(id, "Open in Lily", "arrow.up.left.and.arrow.down.right", #selector(BrowserWindowController.openInLily(_:)))
        default: return nil
        }
    }

    /// Target nil: the action and its validation go through the responder chain to the window controller.
    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.isBordered = true
        item.autovalidates = true
        return item
    }
}
