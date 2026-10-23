import WebKit

/// Hosts the Svelte browser chrome (sidebar) in its own WKWebView.
/// The chrome is trusted first-party content, so its handler lives in the page world,
/// but it only ever loads from the `arc-ui://` scheme.
@MainActor
public final class ChromeHost: NSObject, WKNavigationDelegate {
    public static let messageHandlerName = "chrome"

    public let webView: WKWebView
    public let events = ChromeEventChannel()
    private let bridge: ScriptMessageBridge
    private let schemeHandler: UISchemeHandler

    public init(uiRoot: URL, router: IPCRouter, inspectable: Bool) {
        schemeHandler = UISchemeHandler(root: uiRoot)
        bridge = ScriptMessageBridge(name: Self.messageHandlerName, contentWorld: .page, router: router) { message in
            // Accept only messages from our own UI origin, never from anything navigated into this view.
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == UISchemeHandler.scheme else { return nil }
            return .chrome
        }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: UISchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        bridge.attach(to: controller)
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = inspectable
        webView.setValue(false, forKey: "drawsBackground") // let the sidebar's vibrancy show through
        webView.underPageBackgroundColor = .clear
        super.init()
        webView.navigationDelegate = self
        events.bind(webView)
        webView.load(URLRequest(url: UISchemeHandler.entryURL))
    }

    public func reload() {
        events.reset()
        webView.load(URLRequest(url: UISchemeHandler.entryURL))
    }

    public func tearDown() {
        bridge.detach(from: webView.configuration.userContentController)
        webView.navigationDelegate = nil
    }

    // The chrome view must never navigate away from the UI bundle.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == UISchemeHandler.scheme { return .allow }
        if url.scheme == "http" || url.scheme == "https" {
            onExternalLink?(url)
        }
        return .cancel
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.web.error("Chrome UI process terminated; reloading")
        reload()
    }

    /// Links clicked inside the chrome (e.g. in assistant answers) open as tabs.
    public var onExternalLink: (@MainActor (URL) -> Void)?
}
