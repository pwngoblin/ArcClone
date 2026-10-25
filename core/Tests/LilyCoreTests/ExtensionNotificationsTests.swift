import Foundation
import Testing
import WebKit
@testable import LilyCore

@Suite struct ExtensionNotificationsTests {
    @Test func requestsAreDecodedAndBounded() throws {
        guard #available(macOS 15.4, *) else { return }
        let request = try ExtensionNotifications.decode([
            "action": "create", "id": "n1",
            "options": ["type": "basic", "iconUrl": "i.png", "title": String(repeating: "t", count: 500), "message": "Hi",
                        "buttons": [["title": "One"], ["title": "Two"], ["title": "Three"]]],
        ] as [String: Any])
        #expect(request.action == .create && request.id == "n1")
        #expect(request.options?.title?.count == 256 && request.options?.message == "Hi")
        #expect(request.options?.buttons?.map(\.title) == ["One", "Two"])
    }

    @Test func malformedRequestsAreRefused() {
        guard #available(macOS 15.4, *) else { return }
        for message: Any in [["action": "launch"], ["id": "x"], "create", ["action": "create", "id": String(repeating: "x", count: 300)],
                             ["action": "clear", "id": "a\u{7}b"], ["action": "create", "options": ["title": String(repeating: "x", count: 20_000)]]] {
            #expect(throws: ExtensionNotifications.Refused.self) { try ExtensionNotifications.decode(message) }
        }
    }

    @Test func keysKeepTheExtensionAndID() {
        guard #available(macOS 15.4, *) else { return }
        let key = ExtensionNotifications.key("ABC", "id|with|bars")
        #expect(ExtensionNotifications.parse(key)?.ext == "ABC" && ExtensionNotifications.parse(key)?.id == "id|with|bars")
        #expect(ExtensionNotifications.parse("other") == nil)
    }
}

/// Stands in for Lily's notifications: answers the shim's requests and pushes events, and takes
/// the worker's reports, which it sends as `tabs.create` URLs.
@available(macOS 15.4, *)
@MainActor private final class FakeLily: NSObject, WKWebExtensionControllerDelegate {
    var requests: [[String: Any]] = []
    var reports: [[String: Any]] = []
    var port: WKWebExtension.MessagePort?
    var consoleLines: [String] = []

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == ExtensionConsole.applicationIdentifier, let line = message as? [String: Any] {
            if line["action"] as? String == "enabled" { return true }
            consoleLines.append("\(line["level"] ?? "")|\(line["text"] ?? "")")
            return nil
        }
        guard applicationIdentifier == ExtensionNotifications.applicationIdentifier, let request = message as? [String: Any] else { throw URLError(.badURL) }
        requests.append(request)
        switch request["action"] as? String {
        case "create": return ["id": request["id"] ?? "generated"]
        case "events": return [["type": "clicked", "id": "while-asleep"]]
        case "getAll": return ["ids": ["n1"]]
        default: return ["done": true]
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext) async throws {
        guard port.applicationIdentifier == ExtensionNotifications.applicationIdentifier else { throw URLError(.badURL) }
        self.port = port
        Task { @MainActor in try? await port.sendMessage(["type": "buttonClicked", "id": "n1", "buttonIndex": 1]) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        if let query = configuration.url?.query(percentEncoded: false), let data = query.data(using: .utf8),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { reports.append(report) }
        return nil
    }
}

@Suite @MainActor struct ExtensionNotificationsWebKitTests {
    @Test func theShimSendsNotificationsToLilyAndDeliversEvents() async throws {
        guard #available(macOS 15.4, *) else { return }
        let shim = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../injections/extension-worker-compat.js").standardizedFileURL)
        let original = try ExtensionPackage(files: [
            "manifest.json": Data(#"{"name": "N", "version": "1", "manifest_version": 3, "permissions": ["notifications"], "background": {"service_worker": "bg.js", "type": "module"}}"#.utf8),
            "bg.js": Data("""
            console.warn('early line', { n: 1 });
            const report = (value) => chrome.tabs.create({ url: 'https://report.test/?' + JSON.stringify(value) });
            chrome.notifications.onClicked.addListener((id) => report({ clicked: id }));
            chrome.notifications.onButtonClicked.addListener((id, index) => report({ button: id, index }));
            chrome.notifications.create('n1', { type: 'basic', iconUrl: 'i.png', title: 'Hello', message: 'There', buttons: [{ title: 'A' }, { title: 'B' }] })
              .then((id) => report({ created: id }));
            chrome.notifications.getAll((all) => report({ all: Object.keys(all) }));
            """.utf8),
        ])
        let patched = ExtensionCompat.apply(to: original, shim: shim)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-notify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, data) in patched.files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let lily = FakeLily()
        controller.delegate = lily
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: dir))
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "notifications"))
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try controller.load(context)
        defer { try? controller.unload(context) }
        try await context.loadBackgroundContent()
        for _ in 0..<50 where lily.reports.count < 4 { try await Task.sleep(for: .milliseconds(100)) }

        let reports = lily.reports
        #expect(reports.contains { $0["created"] as? String == "n1" }, "\(reports)")
        #expect(reports.contains { $0["all"] as? [String] == ["n1"] })
        // Collected after waking, and pushed over the port once a notification is showing.
        #expect(reports.contains { $0["clicked"] as? String == "while-asleep" })
        #expect(reports.contains { $0["button"] as? String == "n1" && $0["index"] as? Int == 1 })
        let create = lily.requests.first { $0["action"] as? String == "create" }
        let options = create?["options"] as? [String: Any]
        #expect(create?["id"] as? String == "n1" && options?["title"] as? String == "Hello" && options?["message"] as? String == "There")
        #expect(lily.port != nil)
        // The background's console reaches Lily, including lines written before Lily answered.
        #expect(lily.consoleLines.contains("warn|early line {\"n\":1}"), "\(lily.consoleLines)")
    }
}

@Suite struct ExtensionConsoleTests {
    @Test func linesAreDecodedAndBounded() throws {
        let line = try ExtensionConsole.decode(["action": "log", "level": "warn", "text": String(repeating: "x", count: 3_000)])
        #expect(line.level == .warn && line.text?.count == 2_000)
        #expect(try ExtensionConsole.handle(["action": "enabled"], extensionName: "E", enabled: false) as? Bool == false)
        for bad: Any in [["action": "eval"], ["action": "log", "level": "debug", "text": "x"], "log"] {
            #expect(throws: ExtensionConsole.ExtensionConsoleError.self) { try ExtensionConsole.decode(bad) }
        }
    }
}
