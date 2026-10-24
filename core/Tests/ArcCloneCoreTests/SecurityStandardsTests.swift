import Foundation
import Testing
import WebKit
@testable import ArcCloneCore

/// Checks for the macOS secure development standards in CLAUDE.md that unit tests can observe.
@Suite @MainActor struct SecurityStandardsTests {
    struct Opaque: Error {}

    @Test func errorsShownToUsersHideInternals() {
        // Paths and file URLs are replaced.
        let file = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                           userInfo: [NSLocalizedDescriptionKey: "You can’t open /Users/someone/Library/Containers/x/data.sealed because you don’t have permission."])
        let message = Sanitize.errorMessage(file)
        #expect(!message.contains("/Users") && !message.contains("someone") && message.contains("permission"))
        #expect(!Sanitize.errorMessage(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed at file:///private/var/folders/ab/T/x"])).contains("/private"))
        // Swift errors without a description would print their type names.
        #expect(Sanitize.errorMessage(Opaque()) == "Something went wrong.")
        // Our own messages, and ordinary network errors, stay readable.
        #expect(Sanitize.errorMessage(IPCError("rate_limited", "Too many messages")) == "Too many messages")
        #expect(Sanitize.errorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                              userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])).contains("offline"))
        #expect(Sanitize.errorMessage(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "a", count: 5_000)])).count
                == Sanitize.maxErrorLength)
    }

    /// Pages loaded from file URLs must not read other files or reach other origins.
    @Test func fileURLAccessStaysDisabled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let factory = WebViewFactory(registry: try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json")),
                                     dataStore: .nonPersistent())
        let bridge = ScriptMessageBridge(name: "t", contentWorld: .world(name: "T"), router: IPCRouter()) { _ in nil }
        let config = factory.makeConfiguration(bridge: bridge)
        #expect(config.preferences.value(forKey: "allowFileAccessFromFileURLs") as? Bool == false)
        #expect(config.value(forKey: "allowUniversalAccessFromFileURLs") as? Bool == false)
    }
}
