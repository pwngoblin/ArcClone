import AppKit

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(historyMenu()))
        main.addItem(submenu(tabMenu()))
        main.addItem(submenu(developMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.tag = tag
        return i
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "ArcClone")
        m.addItem(item("About ArcClone", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = submenu(services)
        NSApp.servicesMenu = services
        m.addItem(servicesItem)
        m.addItem(.separator())
        m.addItem(item("Hide ArcClone", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit ArcClone", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"))
        m.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        m.addItem(item("Open Location…", #selector(BrowserWindowController.focusAddressBar(_:)), "l"))
        m.addItem(.separator())
        m.addItem(item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"))
        m.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        m.addItem(item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Copy Link", #selector(BrowserWindowController.copyPageURL(_:)), "c", [.command, .shift]))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(item("Undo", Selector(("undo:")), "z"))
        m.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItem = item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        find.addItem(findItem)
        let next = item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        find.addItem(next)
        m.addItem(submenu(find))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        m.addItem(item("Toggle Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"))
        m.addItem(item("Toggle Assistant", #selector(BrowserWindowController.toggleAssistant(_:)), "e"))
        m.addItem(item("Summarize Page", #selector(BrowserWindowController.summarizePage(_:)), "e", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        m.addItem(item("Reload Ignoring Cache", #selector(BrowserWindowController.hardReloadPage(_:)), "r", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        m.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"))
        m.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        m.addItem(.separator())
        m.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return m
    }

    private static func historyMenu() -> NSMenu {
        let m = NSMenu(title: "History")
        m.addItem(item("Back", #selector(BrowserWindowController.goBack(_:)), "["))
        m.addItem(item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"))
        return m
    }

    private static func tabMenu() -> NSMenu {
        let m = NSMenu(title: "Tabs")
        m.addItem(item("Pin Tab", #selector(BrowserWindowController.togglePinTab(_:)), "d"))
        m.addItem(item("Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", .control))
        m.addItem(item("Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift]))
        m.addItem(.separator())
        for n in 1...9 {
            m.addItem(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        return m
    }

    private static func developMenu() -> NSMenu {
        let m = NSMenu(title: "Develop")
        m.addItem(item("Reload Injections", #selector(BrowserWindowController.reloadInjections(_:)), "i", [.command, .option, .shift]))
        m.addItem(item("Reload Sidebar UI", #selector(BrowserWindowController.reloadChromeUI(_:)), "r", [.command, .option, .shift]))
        m.addItem(item("Restart Agent Bridge", #selector(BrowserWindowController.restartAgentBridge(_:))))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }
}
