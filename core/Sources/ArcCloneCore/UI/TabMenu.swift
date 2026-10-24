import AppKit
import SwiftUI

/// A tab's context menu, defined once: list rows show it through SwiftUI (`TabContextMenu`),
/// pinned tiles as a native `NSMenu` (`TabMenu.menu`). Built when it opens, so it reflects the
/// tab, spaces and split at that moment.
@MainActor
enum TabMenu {
    enum Entry {
        case item(String, symbol: String, destructive: Bool = false, enabled: Bool = true, run: @MainActor () -> Void)
        case share(URL)
        case submenu(String, symbol: String, [Entry])
        case divider
    }

    static func entries(for tab: WindowModel.TabItem, window: WindowModel) -> [Entry] {
        var out: [Entry] = [
            .item("New Tab", symbol: "plus.square") { window.newTab() },
            .item("Duplicate Tab", symbol: "plus.square.on.square") { window.duplicate(tab.id) },
            .item("Reload", symbol: "arrow.clockwise") { window.reload(tab.id) },
            .divider,
            .item(tab.isPinned ? "Unpin Tab" : "Pin Tab", symbol: tab.isPinned ? "pin.slash" : "pin") { window.setPinned(tab.id, !tab.isPinned) },
            .item("Copy Link", symbol: "link", enabled: tab.url != nil) { window.copyLink(tab.id) },
        ]
        if let url = tab.url { out.append(.share(url)) }
        out += [
            .item("Pause Media", symbol: "pause.circle") { window.pauseMedia(tab.id) },
            .divider,
            .item("Open in New Window", symbol: "macwindow.badge.plus", enabled: tab.url != nil) { window.openInNewWindow(tab.id) },
        ]
        let others = window.spaces.filter { $0.id != window.currentSpaceID }
        if !others.isEmpty {
            out.append(.submenu("Move to Space", symbol: "square.stack", others.map { space in
                .item(space.name, symbol: space.symbol) { window.moveTab(tab.id, toSpace: space.id) }
            }))
        }
        if tab.inSplit {
            out.append(.item("Remove from Split View", symbol: "rectangle.split.2x1.slash") { window.removeFromSplit(tab.id) })
        } else {
            if tab.id != window.activeID {
                out.append(.item("Split with Current Tab", symbol: "rectangle.split.2x1") { window.splitWithActive(tab.id) })
            }
            if window.hasSplit && window.splitCanGrow {
                out.append(.item("Add to Split View", symbol: "rectangle.split.3x1") { window.addToSplit(tab.id) })
            }
        }
        out += [
            .divider,
            .item("Close Tab", symbol: "xmark", destructive: true) { window.close(tab.id) },
            .item("Close Other Tabs", symbol: "xmark.square") { window.closeOthers(tab.id) },
            .item("Close Tabs Below", symbol: "arrow.down.to.line") { window.closeBelow(tab.id) },
        ]
        return out
    }

    static func menu(for tab: WindowModel.TabItem, window: WindowModel) -> NSMenu {
        menu(entries(for: tab, window: window))
    }

    private static func menu(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .item(let title, let symbol, _, let enabled, let run):
                let item = ActionMenuItem(title: title, run: run)
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.isEnabled = enabled
                menu.addItem(item)
            case .share(let url):
                let item = NSSharingServicePicker(items: [url]).standardShareMenuItem
                item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                menu.addItem(item)
            case .submenu(let title, let symbol, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.submenu = Self.menu(children)
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            }
        }
        menu.autoenablesItems = false
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

/// The same menu in SwiftUI, for list rows and split pills.
struct TabContextMenu: View {
    let tab: WindowModel.TabItem
    let window: WindowModel

    var body: some View { TabMenuEntries(entries: TabMenu.entries(for: tab, window: window)) }
}

private struct TabMenuEntries: View {
    let entries: [TabMenu.Entry]

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            switch entries[index] {
            case .item(let title, let symbol, let destructive, let enabled, let run):
                Button(role: destructive ? .destructive : nil) { run() } label: { Label(title, systemImage: symbol) }.disabled(!enabled)
            case .share(let url):
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            case .submenu(let title, let symbol, let children):
                Menu { TabMenuEntries(entries: children) } label: { Label(title, systemImage: symbol) }
            case .divider:
                Divider()
            }
        }
    }
}
