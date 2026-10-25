import Foundation
import Testing
import WebKit
@testable import LilyCore

@Suite @MainActor struct ExtensionTests {
    /// A minimal Manifest V3 extension written to a temporary folder.
    func makeExtension() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Hello Test", "version": "1.2.3", "description": "A test extension",
            "permissions": ["storage", "tabs"], "host_permissions": ["https://*.example.com/*"],
            "action": ["default_title": "Hello"],
            "content_scripts": [["matches": ["https://*.example.com/*"], "js": ["content.js"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.hello = '1';".utf8).write(to: dir.appendingPathComponent("content.js"))
        return dir
    }

    @Test func parsesAndLoadsAnUnpackedExtension() async throws {
        guard #available(macOS 15.4, *) else { return }
        let ext = try await WKWebExtension(resourceBaseURL: try makeExtension())
        #expect(ext.displayName == "Hello Test" && ext.displayVersion == "1.2.3")
        #expect(Set(ext.requestedPermissions.map(\.rawValue)).isSuperset(of: ["storage", "tabs"]))
        #expect(ext.allRequestedMatchPatterns.map(\.string).contains("https://*.example.com/*"))
        #expect(ext.hasInjectedContent)

        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        try controller.load(context)
        #expect(context.isLoaded)
        // Nothing is granted until the user approves it.
        #expect(!context.hasPermission(.tabs))
        context.setPermissionStatus(.grantedExplicitly, for: .tabs)
        #expect(context.hasPermission(.tabs))
        try controller.unload(context)
    }

    /// Extension web views (the background's host page, popups, extension pages) must not be
    /// suspended when hidden, or a background freezes mid-task between events.
    @Test func extensionWebViewsAreNotSuspendedWhenHidden() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionManager.configuration().webViewConfiguration?.preferences.inactiveSchedulingPolicy == WKPreferences.InactiveSchedulingPolicy.none)
    }

    @Test func permissionsAreDescribedInPlainLanguage() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionLibrary.describe("tabs") == "Read your open tabs' titles and addresses")
        #expect(ExtensionLibrary.describe("somethingNew") == "somethingNew")
    }
}
