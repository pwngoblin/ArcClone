import Foundation
import WebKit

/// Compatibility mode for macOS 14–15.3, where WebKit has no extension controller: runs the
/// content scripts of the library's verified, pinned extensions as `WKUserScript`s, each extension
/// in its own content world (`ArcExtension.<id>`), so it can't see the page's scripts, ArcClone's
/// injections, or another extension. A first-party shim (`injections/extension-compat.js`) gives
/// those scripts `chrome.storage` and clean errors for APIs that need a background context or
/// native messaging, through `ExtensionMessageBridge`.
///
/// Scripts are chosen by the main frame's address when a page starts loading (WKUserScript has no
/// per-frame match patterns), and `all_frames` scripts then run in that page's frames.
@MainActor
final class ExtensionScriptInjector {
    struct Planned: Equatable {
        let extensionID: String
        let path: String
        let time: WKUserScriptInjectionTime
        let mainFrameOnly: Bool
    }

    let library: ExtensionLibrary
    private let shimSource: String
    private var applied: [ObjectIdentifier: [Planned]] = [:]
    private var bridges: [ObjectIdentifier: [String: ExtensionMessageBridge]] = [:]

    init(library: ExtensionLibrary, shimURL: URL) throws {
        self.library = library
        shimSource = try String(contentsOf: shimURL, encoding: .utf8)
    }

    static func world(for extensionID: String) -> WKContentWorld { .world(name: "ArcExtension.\(extensionID)") }

    /// The content scripts of `entries` that apply to `url`, in manifest order.
    static func plan(for url: URL?, entries: [ExtensionLibrary.Entry]) -> [Planned] {
        guard let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return [] }
        var planned: [Planned] = []
        for entry in entries {
            for script in entry.manifest.contentScripts where Self.matches(script, url) {
                let time: WKUserScriptInjectionTime = script.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
                for path in script.js ?? [] where entry.package.files[path] != nil {
                    planned.append(Planned(extensionID: entry.id, path: path, time: time, mainFrameOnly: !(script.allFrames ?? false)))
                }
            }
        }
        return planned
    }

    static func matches(_ script: ExtensionManifest.ContentScript, _ url: URL) -> Bool {
        script.matches.compactMap(ExtensionMatchPattern.init).contains { $0.matches(url) }
            && !(script.excludeMatches ?? []).compactMap(ExtensionMatchPattern.init).contains { $0.matches(url) }
    }

    /// The CSS of content scripts that apply to `url` for one extension (served to the shim).
    func css(for extensionID: String, url: URL?) -> [String] {
        guard let url, let entry = library.entry(extensionID) else { return [] }
        return entry.manifest.contentScripts.filter { Self.matches($0, url) }.flatMap { $0.css ?? [] }
            .compactMap { entry.package.files[$0].map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Called before a main-frame navigation: re-installs ArcClone's scripts plus the extension
    /// scripts for `url`, only when that set changes.
    func configure(_ controller: WKUserContentController, for url: URL?, registry: ScriptRegistry) {
        let key = ObjectIdentifier(controller)
        let planned = Self.plan(for: url, entries: library.ready)
        guard applied[key, default: []] != planned else { return }
        registry.install(into: controller) // starts from ArcClone's own scripts only
        let needed = Set(planned.map(\.extensionID))
        var attached = bridges[key, default: [:]]
        for (id, bridge) in attached where !needed.contains(id) {
            bridge.detach(from: controller)
            attached[id] = nil
        }
        for id in needed where attached[id] == nil {
            let bridge = ExtensionMessageBridge(extensionID: id, contentWorld: Self.world(for: id), injector: self)
            bridge.attach(to: controller)
            attached[id] = bridge
        }
        bridges[key] = attached
        var shimmed = Set<String>()
        for script in planned {
            guard let entry = library.entry(script.extensionID), let data = entry.package.files[script.path] else { continue }
            let world = Self.world(for: script.extensionID)
            if shimmed.insert(script.extensionID).inserted {
                controller.addUserScript(WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
            }
            controller.addUserScript(WKUserScript(source: String(decoding: data, as: UTF8.self), injectionTime: script.time,
                                                  forMainFrameOnly: script.mainFrameOnly, in: world))
        }
        applied[key] = planned
    }

    /// A tab is closing: drop what was installed for it.
    func forget(_ controller: WKUserContentController) {
        let key = ObjectIdentifier(controller)
        bridges.removeValue(forKey: key)?.values.forEach { $0.detach(from: controller) }
        applied[key] = nil
    }
}
