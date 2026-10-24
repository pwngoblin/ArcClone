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
        main.addItem(submenu(bookmarksMenu()))
        main.addItem(submenu(tabMenu()))
        main.addItem(submenu(developMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
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
        m.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        m.addItem(item("Set as Default Browser…", #selector(AppDelegate.makeDefaultBrowser(_:))))
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
        m.addItem(item("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift]))
        m.addItem(item("Open File…", #selector(AppDelegate.openDocument(_:)), "o"))
        m.addItem(item("Open Location…", #selector(BrowserWindowController.focusAddressBar(_:)), "l"))
        m.addItem(.separator())
        m.addItem(item("Import from Another Browser…", #selector(AppDelegate.showMigration(_:))))
        m.addItem(.separator())
        m.addItem(item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"))
        m.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        m.addItem(item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Copy Link", #selector(BrowserWindowController.copyPageURL(_:)), "c", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"))
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
        m.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        m.addItem(item("Delete", #selector(NSText.delete(_:))))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItem = item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        find.addItem(findItem)
        let next = item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        find.addItem(next)
        let previous = item("Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift])
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        find.addItem(previous)
        m.addItem(submenu(find))

        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        m.addItem(submenu(spelling))

        let substitutions = NSMenu(title: "Substitutions")
        substitutions.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutions.addItem(.separator())
        substitutions.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        substitutions.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        substitutions.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        m.addItem(submenu(substitutions))

        let speech = NSMenu(title: "Speech")
        speech.addItem(item("Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))
        m.addItem(submenu(speech))
        // AppKit appends AutoFill, Start Dictation and Emoji & Symbols to the menu titled "Edit".
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        m.addItem(item("Toggle Sidebar", #selector(BrowserWindowController.toggleSidebar(_:)), "s"))
        m.addItem(item("Toggle Assistant", #selector(BrowserWindowController.toggleAssistant(_:)), "e"))
        let split = NSMenuItem(title: "Split View", action: nil, keyEquivalent: "")
        split.submenu = BrowserWindowController.splitMenu()
        m.addItem(split)
        m.addItem(item("Summarize Page", #selector(BrowserWindowController.summarizePage(_:)), "e", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        m.addItem(item("Reload Ignoring Cache", #selector(BrowserWindowController.hardReloadPage(_:)), "r", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        m.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"))
        m.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        m.addItem(.separator())
        m.addItem(item("Dark Mode for This Site", #selector(BrowserWindowController.toggleSiteDarkMode(_:)), "d", [.command, .option]))
        m.addItem(item("Site Settings…", #selector(BrowserWindowController.showSiteSettings(_:)), ",", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return m
    }

    private static func historyMenu() -> NSMenu {
        let m = NSMenu(title: "History")
        m.addItem(item("Back", #selector(BrowserWindowController.goBack(_:)), "["))
        m.addItem(item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"))
        m.addItem(.separator())
        m.addItem(item("Show All History", #selector(AppDelegate.showHistory(_:)), "y"))
        m.addItem(.separator())
        m.addItem(item("Clear Browsing Data…", #selector(AppDelegate.clearBrowsingData(_:)), "\u{8}", [.command, .shift]))
        return m
    }

    /// Imported bookmarks are added below these items when the menu opens (`BookmarksMenuDelegate`).
    private static func bookmarksMenu() -> NSMenu {
        let m = NSMenu(title: "Bookmarks")
        m.addItem(item("Import from Another Browser…", #selector(AppDelegate.showMigration(_:))))
        m.addItem(item("Remove All Bookmarks…", #selector(AppDelegate.removeAllBookmarks(_:))))
        return m
    }

    private static func tabMenu() -> NSMenu {
        let m = NSMenu(title: "Tabs")
        m.addItem(item("Pin Tab", #selector(BrowserWindowController.togglePinTab(_:)), "d"))
        m.addItem(item("Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", .control))
        m.addItem(item("Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift]))
        m.addItem(.separator())
        m.addItem(item("Next Space", #selector(BrowserWindowController.nextSpace(_:)), "]", [.command, .option]))
        m.addItem(item("Previous Space", #selector(BrowserWindowController.previousSpace(_:)), "[", [.command, .option]))
        m.addItem(.separator())
        for n in 1...9 {
            m.addItem(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        return m
    }

    private static func developMenu() -> NSMenu {
        let m = NSMenu(title: "Develop")
        m.addItem(item("Reload Injections", #selector(BrowserWindowController.reloadInjections(_:)), "i", [.command, .option, .shift]))
        m.addItem(item("Reload Assistant Settings", #selector(BrowserWindowController.reloadAssistant(_:))))
        return m
    }

    private static func helpMenu() -> NSMenu {
        // Assigned to NSApp.helpMenu, so macOS adds the menu-search field on top.
        let m = NSMenu(title: "Help")
        m.addItem(item("ArcClone Help", #selector(AppDelegate.showHelp(_:)), "?"))
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
