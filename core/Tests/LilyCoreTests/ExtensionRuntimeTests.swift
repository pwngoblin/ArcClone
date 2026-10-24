import Foundation
import Testing
import WebKit
@testable import LilyCore

private func package(_ manifest: String, _ files: [String: String] = [:]) throws -> ExtensionPackage {
    var all = files.mapValues { Data($0.utf8) }
    all["manifest.json"] = Data(manifest.utf8)
    return try ExtensionPackage(files: all)
}

@Suite struct ExtensionManifestTests {
    @Test func decodesMV3AndToleratesOddFields() throws {
        let manifest = try #require(ExtensionManifest.parse(package(#"""
        {"manifest_version": 3, "name": "__MSG_appName__", "version": "2.1", "default_locale": "en",
         "permissions": ["storage", {"weird": true}], "host_permissions": ["https://*.example.com/*"],
         "content_scripts": [{"matches": ["https://*/*"], "js": ["content.js"], "run_at": "document_start", "all_frames": true}],
         "background": {"service_worker": "bg.js"}, "action": {"default_popup": "popup.html"},
         "icons": {"16": "i16.png", "128": "i128.png"}, "content_security_policy": 42, "update_url": "https://u.example/x"}
        """#, ["_locales/en/messages.json": #"{"appName": {"message": "Example Helper"}}"#])))
        #expect(manifest.name == "Example Helper" && manifest.version == "2.1" && manifest.manifestVersion == 3)
        #expect(manifest.permissions == ["storage"]) // the object entry is dropped, not fatal
        #expect(manifest.contentSecurityPolicy == nil) // wrong type → absent
        #expect(manifest.contentScripts.first?.runAt == "document_start" && manifest.contentScripts.first?.allFrames == true)
        #expect(manifest.background?.serviceWorker == "bg.js" && manifest.action?.defaultPopup == "popup.html")
        #expect(manifest.iconPath(for: 64) == "i128.png" && manifest.iconPath(for: 16) == "i16.png")
        #expect(manifest.allHostPatterns == ["https://*.example.com/*"])
    }

    @Test func readsMV2Shapes() throws {
        let manifest = try #require(ExtensionManifest.parse(package(#"""
        {"manifest_version": 2, "name": "Old", "version": "1", "permissions": ["tabs", "<all_urls>"],
         "browser_action": {"default_title": "Old"}, "content_security_policy": "script-src 'self'"}
        """#)))
        #expect(manifest.action?.defaultTitle == "Old")
        #expect(manifest.contentSecurityPolicy?.extensionPages == "script-src 'self'")
        #expect(manifest.allHostPatterns == ["<all_urls>"])
    }

    @Test func nameAndVersionAreRequired() throws {
        #expect(ExtensionManifest.parse(try package(#"{"manifest_version": 3}"#)) == nil)
    }

    @Test func matchPatterns() {
        let url = URL(string: "https://mail.example.com/inbox?x=1")!
        #expect(ExtensionMatchPattern("<all_urls>")!.matches(url))
        #expect(ExtensionMatchPattern("*://*.example.com/*")!.matches(url))
        #expect(ExtensionMatchPattern("https://example.com/*")!.matches(URL(string: "https://example.com/")!))
        #expect(!ExtensionMatchPattern("https://example.com/*")!.matches(url))
        #expect(ExtensionMatchPattern("https://*/inbox*")!.matches(url))
        #expect(!ExtensionMatchPattern("*://*/*")!.matches(URL(string: "file:///etc/hosts")!))
        #expect(ExtensionMatchPattern("ftp://x/*") == nil && ExtensionMatchPattern("https://a*b.com/*") == nil)
    }
}

@Suite @MainActor struct ExtensionCompatibilityTests {
    func entry(_ manifest: String, _ files: [String: String]) throws -> ExtensionLibrary.Entry {
        let pkg = try package(manifest, files)
        return ExtensionLibrary.Entry(id: "ext-1", manifest: try #require(ExtensionManifest.parse(pkg)), package: pkg,
                                      folder: URL(fileURLWithPath: "/tmp"), icon: nil)
    }

    @Test func contentScriptsAreChosenByPageAddress() throws {
        let e = try entry(#"""
        {"name": "T", "version": "1", "manifest_version": 3, "content_scripts": [
          {"matches": ["https://*.example.com/*"], "exclude_matches": ["https://admin.example.com/*"], "js": ["a.js", "missing.js"]},
          {"matches": ["<all_urls>"], "js": ["b.js"], "run_at": "document_start", "all_frames": true}]}
        """#, ["a.js": "1", "b.js": "2"])
        let mail = ExtensionScriptInjector.plan(for: URL(string: "https://mail.example.com/")!, entries: [e])
        #expect(mail.map(\.path) == ["a.js", "b.js"]) // listed files only
        #expect(mail[1].time == .atDocumentStart && !mail[1].mainFrameOnly && mail[0].mainFrameOnly)
        #expect(ExtensionScriptInjector.plan(for: URL(string: "https://admin.example.com/")!, entries: [e]).map(\.path) == ["b.js"])
        #expect(ExtensionScriptInjector.plan(for: URL(string: "about:blank"), entries: [e]).isEmpty)
    }

    @Test func eachExtensionGetsItsOwnWorld() {
        #expect(ExtensionScriptInjector.world(for: "a") != ExtensionScriptInjector.world(for: "b"))
        #expect(ExtensionScriptInjector.world(for: "a").name == "LilyExtension.a")
    }

    @Test func bridgeMessagesFollowTheSchema() throws {
        #expect(try ExtensionMessageBridge.decode(#"{"action":"storage.get","payload":{"keys":["a","b"]}}"#) == .storageGet(keys: ["a", "b"]))
        #expect(try ExtensionMessageBridge.decode(#"{"action":"storage.get","payload":{"keys":null}}"#) == .storageGet(keys: nil))
        #expect(try ExtensionMessageBridge.decode(#"{"action":"storage.set","payload":{"items":{"k":1}}}"#) == .storageSet(["k": 1]))
        #expect(try ExtensionMessageBridge.decode(#"{"action":"runtime.connectNative","payload":{"application":"com.1password.1password"}}"#)
                == .nativeMessage(application: "com.1password.1password"))
        for bad: Any in [#"{"action":"eval","payload":"alert(1)"}"#, #"{"payload":{}}"#, #"{"action":"storage.get","payload":{"keys":[1,2]}}"#,
                         #"{"action":"storage.set","payload":{"items":[1]}}"#, 42, String(repeating: "x", count: 1_100_000)] {
            #expect(throws: IPCError.self) { try ExtensionMessageBridge.decode(bad) }
        }
    }

    @Test func shimIsFirstPartyAndClean() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shim = try String(contentsOf: root.appendingPathComponent("injections/extension-compat.js"), encoding: .utf8)
        for banned in ["eval(", "new Function", "innerHTML", "setInterval(", "document.write"] { #expect(!shim.contains(banned), "\(banned)") }
        #expect(shim.contains("messageHandlers.lilyExtension"))
    }
}

@Suite struct ExtensionStorageAndNativeMessagingTests {
    @Test func storageRoundTripsAndEnforcesTheQuota() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-extstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = ExtensionStorage(directory: dir, keys: InMemoryKeyStore())
        try await storage.set("ext", ["theme": "dark", "count": 3])
        #expect(await storage.get("ext", keys: ["theme"]) == ["theme": "dark"])
        #expect(await storage.get("other", keys: nil).isEmpty) // extensions don't share storage
        await storage.remove("ext", keys: ["theme"])
        #expect(await storage.get("ext", keys: nil) == ["count": 3])
        await #expect(throws: ExtensionStorage.QuotaExceeded.self) {
            try await storage.set("ext", ["big": .string(String(repeating: "x", count: ExtensionStorage.quotaBytes))])
        }
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("ExtensionStorage").path)
        #expect(onDisk == ["ext.sealed"])
    }

    @Test func nativeMessagingIsRefusedWithoutStartingAnything() async {
        let refusal = await NativeMessagingHostManager.shared.request(application: "com.1password.1password", extensionName: "1Password")
        #expect(refusal.application == "com.1password.1password")
        #expect(refusal.errorDescription?.contains("Sign in within the extension") == true)
    }
}

/// Compatibility mode end to end in a real web view: shim, content script, bridge and storage.
@Suite @MainActor struct ExtensionCompatibilityWebViewTests {
    @Test func contentScriptRunsIsolatedAndUsesStorage() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-compat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ExtensionLibrary(directory: dir, keys: InMemoryKeyStore())
        let pkg = try package(#"{"name": "Compat", "version": "1", "manifest_version": 3, "content_scripts": [{"matches": ["https://compat.lily.test/*"], "js": ["content.js"], "css": ["content.css"]}]}"#, [
            "content.js": """
            chrome.storage.local.set({ greeting: "hello" }).then(() => chrome.storage.local.get("greeting")).then((items) => {
              document.body.dataset.ext = items.greeting;
              document.body.dataset.pageScriptsVisible = String(typeof window.pageSecret);
              return chrome.runtime.sendNativeMessage("com.1password.1password", {});
            }).catch((error) => { document.body.dataset.native = error.message.includes("desktop apps") ? "refused" : error.message; });
            """,
            "content.css": "#ad { display: none }",
        ])
        let manifest = try #require(ExtensionManifest.parse(pkg))
        library.adoptForTesting(ExtensionLibrary.Entry(id: "compat", manifest: manifest, package: pkg, folder: dir, icon: nil),
                                record: InstalledExtension(id: "compat", enabled: true, grantedPermissions: [], grantedPatterns: []))
        let injector = try ExtensionScriptInjector(library: library, shimURL: root.appendingPathComponent("injections/extension-compat.js"))
        let registry = try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let url = URL(string: "https://compat.lily.test/page")!
        injector.configure(configuration.userContentController, for: url, registry: registry)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body><div id='ad'>ad</div><script>window.pageSecret = 1</script></body></html>", baseURL: url)

        var state: [String] = []
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let result = try? await webView.evaluateJavaScript("""
            [document.body && document.body.dataset.ext, document.body && document.body.dataset.pageScriptsVisible,
             document.body && document.body.dataset.native, getComputedStyle(document.getElementById('ad')).display,
             typeof window.chrome === 'object' && window.chrome.__lilyCompat === true ? 'leaked' : 'isolated'].join('|')
            """)
            state = (result as? String)?.components(separatedBy: "|") ?? []
            if state.count == 5, state[2] != "" { break }
        }
        #expect(state == ["hello", "undefined", "refused", "none", "isolated"], "\(state)")
        #expect(await library.storage.get("compat", keys: nil) == ["greeting": "hello"])
        injector.forget(configuration.userContentController)
    }
}
