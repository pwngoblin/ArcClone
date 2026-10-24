import WebKit

/// Builds web views for tabs. Every tab gets its own WKUserContentController (so script
/// messages identify their tab). Tabs share one persistent website data store, except in spaces
/// with Separate logins, which each get their own cookies, storage and cache.
@MainActor
public final class WebViewFactory {
    public let registry: ScriptRegistry
    public let dataStore: WKWebsiteDataStore
    /// Spaces with Separate logins (`Space.separateLogins`) and their stores, made on first use.
    private var isolatedSpaces: Set<UUID> = []
    private var spaceStores: [UUID: WKWebsiteDataStore] = [:]
    /// Per-site zoom, dark mode, JavaScript and permissions; shared by every window.
    public let siteSettings: SiteSettings?
    /// Private windows apply site settings but never record changes (that would reveal the site).
    public let savesSiteChanges: Bool
    public let adBlocker: AdBlocker?
    /// WKWebExtensionController on macOS 15.4+ (typed loosely so the app still runs on macOS 14).
    /// nil for private windows: extensions never run there.
    public var extensionController: AnyObject?
    /// Compatibility-mode content scripts (macOS 14–15.3); nil in private windows.
    var extensionScripts: ExtensionScriptInjector?
    /// Presents as Safari so sites don't serve degraded "unknown browser" pages, and as *this
    /// Mac's* Safari: an extra "Lily" token, or a Safari version that doesn't match the system's
    /// WebKit, would make Lily users stand out to fingerprinting.
    public var applicationNameForUserAgent = WebViewFactory.safariApplicationName()

    /// "Version/<installed Safari> Safari/605.1.15", as Safari itself sends. Falls back to the
    /// Safari that ships with this macOS when Safari's bundle can't be read.
    nonisolated static func safariApplicationName(safariInfo: URL = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist"),
                                                  system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let installed = (NSDictionary(contentsOf: safariInfo)?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil ? $0 : nil }
        // Safari's major version follows macOS from 26 on; before that, macOS 15 shipped Safari 18, 14 had 17.
        let shipped = system.majorVersion >= 26 ? "\(system.majorVersion).\(system.minorVersion)" : "\(system.majorVersion + 3).0"
        return "Version/\(installed ?? shipped) Safari/605.1.15"
    }

    public init(registry: ScriptRegistry, dataStore: WKWebsiteDataStore = .default(),
                siteSettings: SiteSettings? = nil, savesSiteChanges: Bool = true, adBlocker: AdBlocker? = nil) {
        self.adBlocker = adBlocker
        self.registry = registry
        self.dataStore = dataStore
        self.siteSettings = siteSettings
        self.savesSiteChanges = savesSiteChanges
    }

    // MARK: Workspaces

    /// Private windows keep everything in their one throwaway store.
    public var isolatesSpaces: Bool { dataStore.isPersistent }

    /// The store a tab in `space` uses: the space's own when it has Separate logins.
    public func dataStore(forSpace space: UUID?) -> WKWebsiteDataStore {
        guard isolatesSpaces, let space, isolatedSpaces.contains(space) else { return dataStore }
        if let store = spaceStores[space] { return store }
        let store = WKWebsiteDataStore(forIdentifier: space)
        spaceStores[space] = store
        return store
    }

    func setSeparateLogins(_ separate: Bool, forSpace space: UUID) {
        if separate { isolatedSpaces.insert(space) } else { isolatedSpaces.remove(space) }
    }

    /// Deletes a space's own store (cookies, storage, cache) once no web view uses it.
    func removeSpaceData(_ space: UUID) async {
        isolatedSpaces.remove(space)
        spaceStores[space] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: space)
    }

    /// Clear Browsing Data: the shared store and every space's own store, open or not.
    func removeAllWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        guard isolatesSpaces else { return }
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers {
            await (spaceStores[id] ?? WKWebsiteDataStore(forIdentifier: id)).removeData(ofTypes: types, modifiedSince: .distantPast)
        }
    }

    public func makeConfiguration(bridge: ScriptMessageBridge, space: UUID? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(forSpace: space)
        config.applicationNameForUserAgent = applicationNameForUserAgent
        config.allowsAirPlayForMediaPlayback = true
        // Like Safari: media with sound waits for a click (abuse, battery); muted autoplay still works.
        config.mediaTypesRequiringUserActionForPlayback = [.audio]
        config.preferences.isElementFullscreenEnabled = true
        // No drive-by pop-ups or tab-nabbing windows: new windows need a user gesture.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Unreadably tiny text is a common trick for hidden content and layout-exhaustion pages.
        config.preferences.minimumFontSize = 9
        // Hosts known to support HTTPS are upgraded by WebKit before any request goes out.
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        // Pages that aren't visible (background tabs) have their timers and rendering suspended.
        config.preferences.inactiveSchedulingPolicy = .suspend
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        WebInspector.configure(config.preferences)

        if #available(macOS 15.4, *), let extensions = extensionController as? WKWebExtensionController {
            config.webExtensionController = extensions
        }
        let controller = WKUserContentController()
        registry.install(into: controller)
        bridge.attach(to: controller)
        config.userContentController = controller
        return config
    }

    public func makeWebView(bridge: ScriptMessageBridge, space: UUID? = nil) -> WKWebView {
        let webView = BrowserWebView(frame: .zero, configuration: makeConfiguration(bridge: bridge, space: space))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = WebInspector.isEnabled
        webView.underPageBackgroundColor = .windowBackgroundColor
        return webView
    }
}
