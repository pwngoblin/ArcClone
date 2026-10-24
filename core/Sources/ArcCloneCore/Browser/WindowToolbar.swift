import AppKit

/// The window's native toolbar, Safari/Notes style: sidebar toggle and navigation over the sidebar,
/// the page title and page controls over the content, split by a separator that follows the divider.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    static let back = NSToolbarItem.Identifier("ArcClone.back")
    static let forward = NSToolbarItem.Identifier("ArcClone.forward")
    static let reload = NSToolbarItem.Identifier("ArcClone.reload")
    static let newTab = NSToolbarItem.Identifier("ArcClone.newTab")
    static let siteSettings = NSToolbarItem.Identifier("ArcClone.siteSettings")
    static let darkMode = NSToolbarItem.Identifier("ArcClone.darkMode")
    static let split = NSToolbarItem.Identifier("ArcClone.split")
    static let adBlock = NSToolbarItem.Identifier("ArcClone.adBlock")
    static let extensions = NSToolbarItem.Identifier("ArcClone.extensions")

    let toolbar: NSToolbar

    override init() {
        toolbar = NSToolbar(identifier: "ArcCloneBrowserToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Navigation sits at the start of the content side: over the sidebar, the traffic lights
        // plus four buttons overflowed narrow sidebars and pushed Reload into the » menu.
        [.toggleSidebar, .sidebarTrackingSeparator, Self.back, Self.forward, Self.reload, .flexibleSpace,
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
