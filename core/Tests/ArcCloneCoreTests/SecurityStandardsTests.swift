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

    /// Routes that take no data still refuse anything that isn't empty.
    @Test func emptyPayloadsMustBeEmpty() throws {
        #expect((try? JSONValue.null.decode(PagePayload.Empty.self)) != nil)
        #expect((try? JSONValue.object([:]).decode(PagePayload.Empty.self)) != nil)
        #expect((try? JSONValue.object(["sneaky": "x"]).decode(PagePayload.Empty.self)) == nil)
        #expect((try? JSONValue.string("x").decode(PagePayload.Empty.self)) == nil)
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
        #expect(!config.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(config.preferences.minimumFontSize == 9)
        #expect(config.upgradeKnownHostsToHTTPS)
        #expect(!config.limitsNavigationsToAppBoundDomains) // tabs browse the open web
    }

    @Test func pagesCannotNavigateToFilesOrTopLevelData() {
        let opened = URL(fileURLWithPath: "/Users/me/Documents/report.html")
        #expect(Tab.isAllowedNavigation(opened, isMainFrame: true, allowedData: nil, allowedFile: opened))
        #expect(!Tab.isAllowedNavigation(URL(fileURLWithPath: "/etc/passwd"), isMainFrame: false, allowedData: nil, allowedFile: opened))
        #expect(!Tab.isAllowedNavigation(URL(fileURLWithPath: "/Users/me/.ssh/id_ed25519"), isMainFrame: true, allowedData: nil, allowedFile: nil))
        let data = URL(string: "data:text/html,<form>login</form>")!
        #expect(!Tab.isAllowedNavigation(data, isMainFrame: true, allowedData: nil, allowedFile: nil))
        #expect(Tab.isAllowedNavigation(data, isMainFrame: false, allowedData: nil, allowedFile: nil)) // subframes are sandboxed by WebKit
        #expect(Tab.isAllowedNavigation(URL(string: "https://example.com")!, isMainFrame: true, allowedData: nil, allowedFile: nil))
    }

    @Test func internalPagesNeverUseNilOrFileBaseURLs() {
        #expect(ErrorPage.baseURL(for: URL(string: "https://down.example/x")!).host == "down.example")
        for odd in [nil, URL(fileURLWithPath: "/Users/me/secret.html"), URL(string: "about:blank"), URL(string: "data:text/html,x")] {
            #expect(ErrorPage.baseURL(for: odd) == ErrorPage.internalBaseURL)
        }
        #expect(ErrorPage.isInternal(ErrorPage.internalBaseURL) && !ErrorPage.isInternal(URL(string: "https://example.com")))
        let page = ErrorPage.html(title: "<img src=x onerror=alert(1)>", message: "m", url: nil)
        #expect(page.contains("default-src 'none'") && !page.contains("<img src=x"))
    }
}
