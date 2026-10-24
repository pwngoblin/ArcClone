import WebKit

/// Web developer features (Settings → General), off by default in release builds like Safari's:
/// pages and extension pages become inspectable from Safari's Develop menu (public
/// `isInspectable`), the page's context menu gains Inspect Element, and Develop → Show Web
/// Inspector (⌥⌘I) opens WebKit's inspector in the window. Toggling applies to open pages.
///
/// Inspect Element and Show Web Inspector use WebKit's developer-extras preference and inspector
/// object, which have no public API. Each is used only after checking the method exists, so on a
/// macOS without them those two items are simply unavailable; nothing crashes.
@MainActor
enum WebInspector {
    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        Preferences.flag(Preferences.Key.webDeveloperFeatures, default: false)
        #endif
    }

    /// For a new web view's configuration (`WebViewFactory`).
    static func configure(_ preferences: WKPreferences) {
        setDeveloperExtras(isEnabled, in: preferences)
    }

    /// Applies the current setting to a web view that already exists.
    static func apply(to webView: WKWebView) {
        webView.isInspectable = isEnabled
        setDeveloperExtras(isEnabled, in: webView.configuration.preferences)
    }

    /// Opens the inspector for `webView`, if WebKit offers it.
    static func show(for webView: WKWebView) {
        guard isEnabled, let inspector = inspector(of: webView) else { return }
        _ = inspector.perform(NSSelectorFromString("show"))
    }

    static func canShow(for webView: WKWebView?) -> Bool {
        guard isEnabled, let webView else { return false }
        return inspector(of: webView) != nil
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else { return nil }
        return inspector
    }

    /// Key-value coding resolves "developerExtrasEnabled" to `_setDeveloperExtrasEnabled:` (and
    /// unboxes the Bool); it's checked first, so a missing method can't raise.
    private static func setDeveloperExtras(_ enabled: Bool, in preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else { return }
        preferences.setValue(enabled, forKey: "developerExtrasEnabled")
    }
}
