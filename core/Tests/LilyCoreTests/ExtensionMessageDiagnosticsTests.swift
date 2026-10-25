import Foundation
import Testing
import WebKit
@testable import LilyCore

@available(macOS 15.4, *)
@MainActor private final class ProbeTab: NSObject, WKWebExtensionTab {
    var web: WKWebView?
    weak var owner: ProbeWindow?
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
}

@available(macOS 15.4, *)
@MainActor private final class ProbeWindow: NSObject, WKWebExtensionWindow {
    var tabs: [ProbeTab] = []
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabs.first }
}

/// Lily's console channel, switched on; records what the shim forwards.
@available(macOS 15.4, *)
@MainActor private final class ConsoleLily: NSObject, WKWebExtensionControllerDelegate {
    let window: ProbeWindow
    var lines: [String] = []
    /// The shim asked whether to forward its console (it's ready to log).
    var asked = false
    init(_ window: ProbeWindow) { self.window = window }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [window] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext) async throws -> Any? {
        guard applicationIdentifier == ExtensionConsole.applicationIdentifier, let line = message as? [String: Any] else { throw URLError(.badURL) }
        if line["action"] as? String == "enabled" { asked = true; return true }
        lines.append(line["text"] as? String ?? "")
        return nil
    }
}

@Suite @MainActor struct ExtensionMessageDiagnosticsTests {
    /// The shim's message logger sees what a page sends the background without getting in the way
    /// of the extension's own (asynchronous) reply.
    @Test func receivedMessagesAreLoggedAndStillAnswered() async throws {
        guard #available(macOS 15.4, *) else { return }
        let shim = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../injections/extension-worker-compat.js").standardizedFileURL)
        let original = try ExtensionPackage(files: [
            "manifest.json": Data(#"{"name": "M", "version": "1", "description": "d", "manifest_version": 3, "host_permissions": ["https://example.com/*"], "background": {"service_worker": "bg.js", "type": "module"}, "content_scripts": [{"matches": ["https://example.com/*"], "js": ["cs.js"], "run_at": "document_idle"}]}"#.utf8),
            "bg.js": Data("chrome.runtime.onMessage.addListener((m, s, reply) => { if (m.name !== 'sign-in-succeeded') return false; setTimeout(() => reply({ type: 'Success', data: 'pong' }), 50); return true; });".utf8),
            "cs.js": Data("""
            chrome.runtime.sendMessage({ name: 'new-tab-log-event', data: { msg: 'hello' } });
            chrome.runtime.sendMessage({ name: 'sign-in-succeeded', data: { secret: 'not logged' } }, (o) => { document.title = 'R:' + JSON.stringify(o); });
            """.utf8),
        ])
        let patched = ExtensionCompat.apply(to: original, shim: shim)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-msgdiag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try patched.write(to: dir)

        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let window = ProbeWindow(), tab = ProbeTab()
        tab.owner = window
        window.tabs = [tab]
        let lily = ConsoleLily(window)
        controller.delegate = lily
        let ext = try await WKWebExtension(resourceBaseURL: dir)
        let context = WKWebExtensionContext(for: ext)
        for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try controller.load(context)
        defer { try? controller.unload(context) }
        // The page's message must find the background running and the shim forwarding: on a busy
        // machine a fixed delay wasn't always enough.
        try await context.loadBackgroundContent()
        for _ in 0..<100 where !lily.asked { try await Task.sleep(for: .milliseconds(50)) }
        #expect(lily.asked)
        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        tab.web = web
        controller.didOpenWindow(window)
        controller.didOpenTab(tab)
        web.loadHTMLString("<title>page</title>", baseURL: URL(string: "https://example.com/")!)
        for _ in 0..<200 where !(web.title ?? "").hasPrefix("R:") || lily.lines.count < 3 { try await Task.sleep(for: .milliseconds(100)) }

        #expect(web.title == #"R:{"type":"Success","data":"pong"}"#)
        #expect(lily.lines.contains { $0.hasPrefix("[Lily] received <sign-in-succeeded> from example.com tab") }, "\(lily.lines)")
        #expect(lily.lines.contains(#"[page log] {"msg":"hello"}"#), "\(lily.lines)")
        #expect(!lily.lines.contains { $0.contains("not logged") })
        // The extension's own reply is reported by kind and delay.
        #expect(lily.lines.contains { $0.hasPrefix("[Lily] reply <sign-in-succeeded>: Success after") }, "\(lily.lines)")
    }
}
