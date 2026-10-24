import AppKit

/// Something the command palette (⌘K) can run: a main-menu command, a space to switch to, or an
/// extension's toolbar action. Menu commands are read from the live main menu each time the
/// palette opens, so the palette always offers exactly what the menus do, with the same
/// shortcuts and the same enabled state, and never needs its own list kept in sync.
struct PaletteCommand: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The item and who handles it in the palette's window, resolved when the palette opens.
        case menu(NSMenuItem, target: AnyObject?)
        case space(UUID)
        case extensionAction(String)

        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case let (.menu(x, _), .menu(y, _)): x === y
            case let (.space(x), .space(y)): x == y
            case let (.extensionAction(x), .extensionAction(y)): x == y
            default: false
            }
        }
    }

    let id: String
    let title: String
    /// Where it lives ("View › Split View"), shown under the title.
    let path: String
    let shortcut: String?
    let symbol: String
    let kind: Kind
    /// Lowercased title and path, for matching.
    let haystack: String

    init(id: String, title: String, path: String, shortcut: String? = nil, symbol: String, kind: Kind) {
        self.id = id
        self.title = title
        self.path = path
        self.shortcut = shortcut
        self.symbol = symbol
        self.kind = kind
        haystack = "\(title) \(path)".lowercased()
    }

    /// Lower is better; nil when a word of the query is missing.
    func score(_ words: [Substring]) -> Int? {
        let title = title.lowercased()
        var score = 0
        for word in words {
            if title.hasPrefix(word) { continue }
            if title.contains(" \(word)") { score += 1 } else if haystack.contains(word) { score += 2 } else { return nil }
        }
        return score
    }

    /// Runs it once the palette has closed, sent to the handler found in the palette's window, as
    /// choosing it from the menu bar in that window would.
    @MainActor
    func perform(in window: WindowModel) {
        switch kind {
        case .menu(let item, let target):
            guard let action = item.action else { return }
            Task { @MainActor in NSApplication.shared.sendAction(action, to: target, from: item) }
        case .space(let id):
            window.switchSpace(to: id)
        case .extensionAction(let id):
            if #available(macOS 15.4, *) {
                ((NSApp.delegate as? AppDelegate)?.extensionRuntime as? ExtensionManager)?.performAction(id)
            }
        }
    }
}

@MainActor
enum PaletteCommands {
    /// Menus whose items act on selected text (they'd only edit the palette's own field) or list
    /// windows; Find stays, since it searches the page.
    private static let skippedSubmenus: Set<String> = ["Spelling and Grammar", "Substitutions", "Speech", "Transformations", "AutoFill"]

    /// Everything the palette can run right now, in menu order.
    static func all(in window: WindowModel) -> [PaletteCommand] {
        // From the page, not the palette's text field, so Find searches the page.
        let start: NSResponder? = window.controller?.tabs.active.flatMap { $0.hasWebView ? $0.webView : nil } ?? window.controller?.window
        var out = NSApp.mainMenu.map { commands(in: $0, from: start) } ?? []
        for space in window.spaces where space.id != window.currentSpaceID {
            out.append(PaletteCommand(id: "space:\(space.id.uuidString)", title: "Switch to \(space.name)", path: "Spaces",
                                      symbol: space.symbol, kind: .space(space.id)))
        }
        if #available(macOS 15.4, *), let app = NSApp.delegate as? AppDelegate, app.extensionRuntime is ExtensionManager {
            for entry in app.extensionLibrary?.ready ?? [] {
                out.append(PaletteCommand(id: "extension:\(entry.id)", title: "Open \(entry.name)", path: "Extensions",
                                          symbol: "puzzlepiece.extension", kind: .extensionAction(entry.id)))
            }
        }
        return out
    }

    /// The enabled commands in `menu` and its submenus, as handled from `start` (a responder in
    /// the palette's window). Validated against that window rather than whichever is key, so the
    /// palette is right even when another window has focus.
    static func commands(in menu: NSMenu, from start: NSResponder? = nil) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        collect(menu, path: [], from: start, into: &out)
        return out
    }

    private static func collect(_ menu: NSMenu, path: [String], from start: NSResponder?, into out: inout [PaletteCommand]) {
        guard menu !== NSApplication.shared.servicesMenu else { return }
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
            if let submenu = item.submenu {
                guard !skippedSubmenus.contains(item.title) else { continue }
                collect(submenu, path: path + [item.title], from: start, into: &out)
                continue
            }
            guard let action = item.action, !item.title.isEmpty, isCommand(item, action: action, path: path) else { continue }
            let target = handler(of: action, item: item, from: start)
            // Menus that validate themselves ask the handler; hand-enabled ones (tests) say so directly.
            let enabled = menu.autoenablesItems ? target.map { validate(item, with: $0) } ?? false : item.isEnabled
            guard enabled else { continue }
            let where_ = path.joined(separator: " › ")
            out.append(PaletteCommand(id: "menu:\(where_)/\(item.title)/\(item.tag)", title: item.title, path: where_,
                                      shortcut: shortcut(item), symbol: symbol(for: path.first), kind: .menu(item, target: target)))
        }
    }

    /// Who would handle `action`, the way AppKit finds it: the item's own target, else up the
    /// responder chain from `start` (view, window, window controller), then the app and its delegate.
    private static func handler(of action: Selector, item: NSMenuItem, from start: NSResponder?) -> AnyObject? {
        if let target = item.target { return target.responds(to: action) ? target : nil }
        var responder = start
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        let app = NSApplication.shared
        if app.responds(to: action) { return app }
        if let delegate = app.delegate, delegate.responds(to: action) { return delegate }
        return nil
    }

    private static func validate(_ item: NSMenuItem, with target: AnyObject) -> Bool {
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    private static func isCommand(_ item: NSMenuItem, action: Selector, path: [String]) -> Bool {
        // History and bookmark rows (already searched as pages), the Window menu's window list,
        // and the palette itself.
        if item.representedObject is URL || action == #selector(NSWindow.makeKeyAndOrderFront(_:))
            || action == #selector(BrowserWindowController.showCommandPalette(_:)) { return false }
        // Edit commands act on the focused text, which would be the palette itself; Find searches the page.
        if path.first == "Edit" { return path.count > 1 && path[1] == "Find" }
        return true
    }

    private static func symbol(for menu: String?) -> String {
        switch menu {
        case "File": "doc"
        case "Edit": "magnifyingglass"
        case "View": "eye"
        case "History": "clock.arrow.circlepath"
        case "Bookmarks": "bookmark"
        case "Tabs": "square.on.square"
        case "Develop": "hammer"
        case "Window": "macwindow"
        case "Help": "questionmark.circle"
        default: "command"
        }
    }

    /// "⌥⌘D", as the menu shows it.
    static func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        switch item.keyEquivalent {
        case "\t": text += "⇥"
        case "\u{8}": text += "⌫"
        case "\r": text += "↩"
        case " ": text += "Space"
        default: text += item.keyEquivalent.uppercased()
        }
        return text
    }
}
