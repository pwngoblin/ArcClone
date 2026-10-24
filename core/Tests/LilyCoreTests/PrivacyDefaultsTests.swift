import Foundation
import Testing
import WebKit
@testable import LilyCore

@Suite(.serialized) @MainActor struct PrivacyDefaultsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Runs `body` with `key` set to `value` (nil: unset), then puts back what was there.
    private func with(_ key: String, _ value: Any?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        try body()
    }

    @Test func searchesGoToDuckDuckGoUnlessYouChoseAnother() {
        with(Preferences.Key.searchEngine, nil) {
            #expect(Preferences.searchEngine == .duckDuckGo)
            #expect(Preferences.urlResolver.searchURL(for: "lily")?.host == "duckduckgo.com")
        }
        with(Preferences.Key.searchEngine, "google") { #expect(Preferences.searchEngine == .google) } // a choice is kept
        #expect(URLResolver().searchURL(for: "x")?.host == "duckduckgo.com")
    }

    @Test func fraudWarningsFollowTheSetting() throws {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        let factory = WebViewFactory(registry: registry, dataStore: .nonPersistent())
        let bridge = { ScriptMessageBridge(name: "t", contentWorld: .page, router: IPCRouter()) { _ in nil } }
        try with(Preferences.Key.fraudulentSiteWarnings, nil) {
            #expect(factory.makeConfiguration(bridge: bridge()).preferences.isFraudulentWebsiteWarningEnabled) // on by default
        }
        try with(Preferences.Key.fraudulentSiteWarnings, false) {
            #expect(!factory.makeConfiguration(bridge: bridge()).preferences.isFraudulentWebsiteWarningEnabled)
        }
    }
}
