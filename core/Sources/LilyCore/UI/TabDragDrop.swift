import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A tab dragged in the sidebar (its id), readable only inside Lily; declared in Info.plist.
    static let lilyTab = UTType(exportedAs: "dev.lily.browser.tab", conformingTo: .data)
}

/// What a sidebar drop target received: one of this window's tabs, or a link dragged from a page
/// or another app.
enum TabDrop: Transferable {
    case tab(UUID)
    case link(URL)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .lilyTab) { data in
            guard let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { throw CocoaError(.coderReadCorrupt) }
            return .tab(id)
        }
        ProxyRepresentation(importing: { (url: URL) in TabDrop.link(url) })
    }

    /// Links worth opening as tabs: web addresses only (no file:, javascript: or data: drops).
    var webLink: URL? {
        guard case .link(let url) = self, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

enum TabDrag {
    /// A dragged tab: inside Lily its id (`ownProcess`, so other apps never see it); to other
    /// apps, its web address.
    @MainActor
    static func provider(for tab: WindowModel.TabItem) -> NSItemProvider {
        Haptics.tap() // picked up
        let provider = tab.url.flatMap { url in url.scheme?.hasPrefix("http") == true ? NSItemProvider(object: url as NSURL) : nil } ?? NSItemProvider()
        let id = Data(tab.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.lilyTab.identifier, visibility: .ownProcess) { done in
            done(id, nil)
            return nil
        }
        provider.suggestedName = tab.title
        return provider
    }

    /// A dragged tile for AppKit drags (pinned tiles): the tab's id under the in-app type, and its
    /// web address for other apps. The id is a random identifier with no meaning outside Lily.
    @MainActor
    static func pasteboardItem(for tab: WindowModel.TabItem) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(tab.id.uuidString, forType: NSPasteboard.PasteboardType(UTType.lilyTab.identifier))
        if let url = tab.url, url.scheme?.hasPrefix("http") == true {
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
        }
        return item
    }

    /// What an AppKit drag carries: one of our tabs (from a tile or a list row), or a link.
    @MainActor
    static func read(_ pasteboard: NSPasteboard) -> TabDrop? {
        if let raw = pasteboard.string(forType: NSPasteboard.PasteboardType(UTType.lilyTab.identifier)), let id = UUID(uuidString: raw) {
            return .tab(id)
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first { return .link(url) }
        return nil
    }

    /// What the first provider holds, for List's `onInsert` (which hands over providers, not values).
    /// The providers stay on the main actor; only the loaded bytes or URL cross back.
    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> TabDrop? {
        guard let provider = providers.first else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.lilyTab.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.lilyTab.identifier) { data, _ in continuation.resume(returning: data) }
            }
            return data.flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) }.map(TabDrop.tab)
        }
        if provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            return url.map(TabDrop.link)
        }
        return nil
    }
}

extension View {
    /// Highlights a drop target and taps the trackpad as a drag moves onto it.
    func tabDropTarget(_ targeted: Binding<Bool>, perform: @escaping (TabDrop) -> Bool) -> some View {
        dropDestination(for: TabDrop.self) { items, _ in
            guard let item = items.first else { return false }
            return perform(item)
        } isTargeted: { isOver in
            if isOver && !targeted.wrappedValue { Haptics.snap() }
            targeted.wrappedValue = isOver
        }
    }
}
