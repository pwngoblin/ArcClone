import AppKit
import Testing
@testable import LilyCore

@Suite @MainActor struct CommandPaletteTests {
    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ flags: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false // no responder chain in tests; enabled state is set by hand
        items.forEach(menu.addItem)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    @Test func readsCommandsFromTheMenus() {
        let disabled = item("Pin Tab", #selector(BrowserWindowController.togglePinTab(_:)), "d")
        disabled.isEnabled = false
        let historyRow = item("Example", #selector(AppDelegate.openHistoryItem(_:)))
        historyRow.representedObject = URL(string: "https://example.com")!
        let main = NSMenu()
        main.autoenablesItems = false
        for parent in [
            menu("View", [item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"), .separator(),
                          menu("Split View", [item("Two Panes", #selector(BrowserWindowController.splitView(_:)), "1", [.command, .control])])]),
            menu("Edit", [item("Copy", #selector(NSText.copy(_:)), "c"), menu("Find", [item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f")])]),
            menu("Tabs", [disabled]),
            menu("History", [item("Back", #selector(BrowserWindowController.goBack(_:)), "["), historyRow]),
            menu("File", [item("Command Palette…", #selector(BrowserWindowController.showCommandPalette(_:)), "k")]),
        ] { main.addItem(parent) }

        let commands = PaletteCommands.commands(in: main)
        #expect(commands.map(\.title) == ["Reload Page", "Two Panes", "Find…", "Back"])
        #expect(commands.map(\.path) == ["View", "View › Split View", "Edit › Find", "History"])
        #expect(commands.first?.shortcut == "⌘R")
        #expect(commands[1].shortcut == "⌃⌘1")
    }

    @Test func shortcutsReadLikeTheMenuBar() {
        #expect(PaletteCommands.shortcut(item("x", nil, "\t", [.control, .shift])) == "⌃⇧⇥")
        #expect(PaletteCommands.shortcut(item("x", nil, "d", [.command, .option])) == "⌥⌘D")
        #expect(PaletteCommands.shortcut(item("x", nil, "\u{8}", [.command, .shift])) == "⇧⌘⌫")
        #expect(PaletteCommands.shortcut(item("x", nil)) == nil)
    }

    @Test func matchingPrefersTitlePrefixesAndNeedsEveryWord() {
        let reload = PaletteCommand(id: "a", title: "Reload Page", path: "View", symbol: "eye", kind: .space(UUID()))
        let hard = PaletteCommand(id: "b", title: "Reload Ignoring Cache", path: "View", symbol: "eye", kind: .space(UUID()))
        let dark = PaletteCommand(id: "c", title: "Dark Mode for This Site", path: "View", symbol: "eye", kind: .space(UUID()))
        #expect(reload.score(["rel"]) == 0)
        #expect(dark.score(["mode"]) == 1)  // start of a later word
        #expect(dark.score(["view"]) == 2)  // only in the path
        #expect(hard.score(["reload", "cache"]) == 1)
        #expect(reload.score(["reload", "cache"]) == nil)
    }
}
