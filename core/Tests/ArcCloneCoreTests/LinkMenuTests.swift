import AppKit
import Testing
@testable import ArcCloneCore

@Suite @MainActor struct LinkMenuTests {
    func item(_ id: String, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    @Test func webKitItemsGetIconsAndTabWording() {
        let menu = NSMenu()
        menu.addItem(item("WKMenuItemIdentifierOpenLinkInNewWindow", "Open Link in New Window"))
        menu.addItem(item("WKMenuItemIdentifierCopyLink", "Copy Link"))
        menu.addItem(item("WKMenuItemIdentifierInspectElement", "Inspect Element"))
        menu.addItem(item("SomethingWebKitAddsLater", "Unknown"))
        BrowserWebView.restyle(menu)
        #expect(menu.items[0].title == "Open Link in New Tab")
        #expect(menu.items.prefix(3).allSatisfy { $0.image != nil })
        #expect(menu.items[2].title == "Inspect Element") // WebKit's own wording kept
        #expect(menu.items[3].image == nil && menu.items[3].title == "Unknown") // unknown items untouched
    }

    @Test func everySymbolExists() {
        for (id, style) in BrowserWebView.restyle {
            #expect(NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil) != nil, "\(id): \(style.symbol)")
        }
        #expect(NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil) != nil)
    }
}
