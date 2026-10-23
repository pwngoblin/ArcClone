import WebKit

/// Builds web views for tabs. Every tab gets its own WKUserContentController (so script
/// messages identify their tab) while sharing one persistent website data store.
@MainActor
public final class WebViewFactory {
    public let registry: ScriptRegistry
    public let dataStore: WKWebsiteDataStore
    /// Per-site zoom, dark mode, JavaScript and permissions; shared by every window.
    public let siteSettings: SiteSettings?
    /// Private windows apply site settings but never record changes (that would reveal the site).
    public let savesSiteChanges: Bool
    public let adBlocker: AdBlocker?
    /// WKWebExtensionController on macOS 15.4+ (typed loosely so the app still runs on macOS 14).
    /// nil for private windows: extensions never run there.
    public var extensionController: AnyObject?
    /// Web Inspector is a development tool: release builds don't let it attach to tabs or the chrome.
    #if DEBUG
    public var inspectable = true
    #else
    public var inspectable = false
    #endif

    /// Presents as Safari so sites don't serve degraded "unknown browser" pages.
    public var applicationNameForUserAgent = "Version/18.0 Safari/605.1.15 ArcClone/0.1"

    public init(registry: ScriptRegistry, dataStore: WKWebsiteDataStore = .default(),
                siteSettings: SiteSettings? = nil, savesSiteChanges: Bool = true, adBlocker: AdBlocker? = nil) {
        self.adBlocker = adBlocker
        self.registry = registry
        self.dataStore = dataStore
        self.siteSettings = siteSettings
        self.savesSiteChanges = savesSiteChanges
    }

    public func makeConfiguration(bridge: ScriptMessageBridge) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = applicationNameForUserAgent
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        if #available(macOS 15.4, *), let extensions = extensionController as? WKWebExtensionController {
            config.webExtensionController = extensions
        }
        let controller = WKUserContentController()
        registry.install(into: controller)
        bridge.attach(to: controller)
        config.userContentController = controller
        return config
    }

    public func makeWebView(bridge: ScriptMessageBridge) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(bridge: bridge))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = inspectable
        webView.underPageBackgroundColor = .windowBackgroundColor
        return webView
    }
}
