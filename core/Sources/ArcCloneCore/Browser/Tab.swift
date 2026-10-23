import WebKit

@MainActor
public protocol TabDelegate: AnyObject {
    func tabDidChange(_ tab: Tab)
    func tab(_ tab: Tab, requestsNewTabWith request: URLRequest, inBackground: Bool)
    func tabRequestsClose(_ tab: Tab)
}

/// One browsing tab: owns its WKWebView, its IPC bridge, crash recovery and downloads.
@MainActor
public final class Tab: NSObject {
    public let id: UUID
    public let webView: WKWebView
    public weak var delegate: TabDelegate?

    public private(set) var title: String = ""
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var progress: Double = 0
    public private(set) var faviconURL: URL?
    public private(set) var themeColor: String?
    public private(set) var lastSelection: String?
    public private(set) var youtubeVideoID: String?
    public var isPinned = false
    public private(set) var lastActivated = Date()

    private let bridge: ScriptMessageBridge
    private let contentWorld: WKContentWorld
    private var observations: [NSKeyValueObservation] = []
    private var crashTimes: [Date] = []
    private var pendingURL: URL?
    /// The original http:// URL while its HTTPS-First upgrade is loading.
    private var upgradedFrom: URL?
    private var isDiscarded = false

    public init(id: UUID = UUID(), factory: WebViewFactory, router: IPCRouter, url: URL?, pinned: Bool = false) {
        self.id = id
        self.isPinned = pinned
        self.contentWorld = factory.registry.contentWorld
        let tabID = id
        self.bridge = ScriptMessageBridge(name: ScriptRegistry.messageHandlerName,
                                          contentWorld: factory.registry.contentWorld,
                                          router: router) { message in
            .page(tabID: tabID, isMainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url)
        }
        self.webView = factory.makeWebView(bridge: bridge)
        self.url = url
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
        if let url { load(url) }
    }

    /// Breaks the WKUserContentController -> bridge retain and stops the page.
    public func tearDown() {
        observations.removeAll()
        bridge.detach(from: webView.configuration.userContentController)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        isDiscarded = true
    }

    // MARK: Navigation

    public func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func reload() { webView.reload() }
    public func stop() { webView.stopLoading() }

    public func markActivated() { lastActivated = Date() }

    // MARK: Injection calls (native -> page)

    /// Invokes a handler registered with `window.__arc.register` in the main frame.
    public func callInjection(_ name: String, _ args: JSONValue = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        let body = """
        if (!window.__arc) { return JSON.stringify({ ok: false, error: { code: "not_injected", message: "Injection runtime not loaded on this page" } }); }
        return await window.__arc.invoke(name, argsJSON);
        """
        let raw: String = try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            webView.callAsyncJavaScript(body, arguments: ["name": name, "argsJSON": args.jsonString()],
                                        in: nil, in: contentWorld) { result in
                guard gate.open() else { return }
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) ?? "null")
                case .failure(let error):
                    continuation.resume(throwing: IPCError("injection_failed", error.localizedDescription))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard gate.open() else { return }
                continuation.resume(throwing: IPCError("timeout", "\(name) timed out"))
            }
        }
        let reply = try JSONValue.parse(raw)
        if reply["ok"]?.bool == true { return reply["result"] ?? .null }
        let err = reply["error"]
        throw IPCError(err?["code"]?.string ?? "injection_error", err?["message"]?.string ?? "Injection call failed")
    }

    // MARK: Page events (page -> native), applied by the window's page handlers

    func applyMetadata(_ payload: JSONValue) {
        if let s = payload["favicon"]?.string, let u = URL(string: s) { faviconURL = u }
        themeColor = payload["themeColor"]?.string
        if let t = payload["title"]?.string, !t.isEmpty, t != title { title = t }
        notify()
    }

    func applySelection(_ text: String?) {
        lastSelection = (text?.isEmpty ?? true) ? nil : text
    }

    func applyYouTubeVideo(_ id: String?) {
        youtubeVideoID = id
        notify()
    }

    // MARK: Snapshot

    public var snapshot: JSONValue {
        [
            "id": .string(id.uuidString),
            "title": .string(title.isEmpty ? (url?.host ?? "New Tab") : title),
            "url": JSONValue(url?.absoluteString),
            "favicon": JSONValue(faviconURL?.absoluteString),
            "isLoading": .bool(isLoading),
            "progress": .number(progress),
            "pinned": .bool(isPinned),
            "canGoBack": .bool(webView.canGoBack),
            "canGoForward": .bool(webView.canGoForward),
            "isYouTubeVideo": .bool(youtubeVideoID != nil),
            "themeColor": JSONValue(themeColor),
        ]
    }

    // MARK: Private

    private func observe() {
        func watch<V>(_ kp: KeyPath<WKWebView, V>, _ apply: @escaping @MainActor (Tab) -> Void) -> NSKeyValueObservation {
            webView.observe(kp, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                }
            }
        }
        observations = [
            watch(\.title) { tab in
                if let t = tab.webView.title, !t.isEmpty { tab.title = t }
                tab.notify()
            },
            watch(\.url) { tab in
                if let u = tab.webView.url {
                    if tab.url?.host != u.host { tab.faviconURL = nil }
                    tab.url = u
                }
                tab.notify()
            },
            watch(\.isLoading) { tab in tab.isLoading = tab.webView.isLoading; tab.notify() },
            watch(\.estimatedProgress) { tab in tab.progress = tab.webView.estimatedProgress; tab.notify() },
            watch(\.canGoBack) { tab in tab.notify() },
            watch(\.canGoForward) { tab in tab.notify() },
        ]
    }

    private func notify() {
        guard !isDiscarded else { return }
        delegate?.tabDidChange(self)
    }

    private func showError(_ error: Error, for failingURL: URL?) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if let original = upgradedFrom {
            upgradedFrom = nil
            offerHTTPFallback(to: original, error: nsError)
            return
        }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return } // policy change / plug-in handled
        let target = failingURL ?? (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
        webView.loadHTMLString(ErrorPage.html(title: "Can't open this page",
                                              message: nsError.localizedDescription,
                                              url: target),
                               baseURL: target)
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        let isLink = navigationAction.navigationType == .linkActivated
        let wantsNewTab = navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 4 // middle click
        if isLink && wantsNewTab {
            delegate?.tab(self, requestsNewTabWith: navigationAction.request,
                          inBackground: !navigationAction.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        if let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame ?? true,
           (navigationAction.request.httpMethod ?? "GET") == "GET", navigationAction.navigationType != .backForward,
           url.scheme?.lowercased() == "http", let host = url.host?.lowercased() {
            if let original = upgradedFrom, original.host?.lowercased() == host {
                // The HTTPS endpoint itself redirects to HTTP: the site insists, so stop upgrading it.
                Log.web.info("HTTPS-First: site redirects back to HTTP")
                HTTPSFirst.allowedHTTPHosts.insert(host)
                upgradedFrom = nil
            } else if let secure = HTTPSFirst.upgrade(url) {
                upgradedFrom = url
                Task { [weak self] in self?.webView.load(URLRequest(url: secure)) }
                return (.cancel, preferences)
            }
        }
        if let url = navigationAction.request.url, Self.opensExternally(url) {
            // mailto:, zoommtg:, etc. go to another app, but only after the user agrees,
            // and never on behalf of a subframe (ads, embeds).
            if navigationAction.targetFrame?.isMainFrame ?? true { confirmExternalOpen(url) }
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    /// The HTTPS-First upgrade failed: explain the risk and let the user continue over HTTP.
    private func offerHTTPFallback(to url: URL, error: NSError) {
        guard let host = url.host?.lowercased() else { return }
        let alert = NSAlert()
        alert.messageText = "“\(host)” doesn't support a secure connection"
        alert.informativeText = "Anyone on your network could see or change what you send to and receive from this site over HTTP.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "Continue to HTTP")
        alert.addButton(withTitle: "Cancel")
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                HTTPSFirst.allowedHTTPHosts.insert(host)
                self.load(url)
            } else {
                self.webView.loadHTMLString(ErrorPage.html(title: "Secure connection unavailable", message: error.localizedDescription, url: url),
                                            baseURL: nil)
            }
        }
        if let window = webView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            finish(alert.runModal())
        }
    }

    nonisolated static func opensExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme)
    }

    /// Like Safari: "Do you want to allow this page to open “Zoom”?" as a sheet on the tab's window.
    private func confirmExternalOpen(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            Log.web.info("No handler for \(url.scheme ?? "?", privacy: .public): link")
            return
        }
        // One prompt at a time, so a page can't stack up dialogs.
        guard let window = webView.window, window.attachedSheet == nil else { return }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Do you want to allow this page to open “\(appName)”?"
        alert.informativeText = "\(self.url?.host ?? "This page") wants to open a \(url.scheme ?? "")\u{3A} link."
        alert.icon = NSWorkspace.shared.icon(forFile: app.path)
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment"), navigationResponse.isForMainFrame {
            return .download
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pendingURL = webView.url
        youtubeVideoID = nil
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        upgradedFrom = nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notify()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, for: pendingURL)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.web.info("Navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Web content process crash recovery: reload up to 3 times per minute, then show an error page.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        Log.web.error("Web content process terminated for tab \(self.id.uuidString, privacy: .public) (\(self.crashTimes.count) in last minute)")
        if crashTimes.count <= 3 {
            if webView.url != nil { webView.reload() } else if let url { load(url) }
        } else {
            webView.loadHTMLString(ErrorPage.html(title: "This page keeps crashing",
                                                  message: "The page's web content process terminated repeatedly. Reload to try again.",
                                                  url: url), baseURL: nil)
        }
    }

    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    /// target=_blank and window.open: open as a foreground tab instead of a popup window.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url != nil {
            delegate?.tab(self, requestsNewTabWith: navigationAction.request, inBackground: false)
        }
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabRequestsClose(self)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.runModal()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .prompt
    }
}

/// Resumes a continuation exactly once across racing callbacks (result vs. timeout).
@MainActor
final class OnceGate {
    private var used = false
    func open() -> Bool {
        if used { return false }
        used = true
        return true
    }
}

enum ErrorPage {
    static func html(title: String, message: String, url: URL?) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px -apple-system, system-ui; display: grid; place-items: center; height: 100vh; margin: 0; }
          main { max-width: 460px; padding: 24px; }
          h1 { font-size: 20px; margin: 0 0 8px; }
          p { opacity: .75; line-height: 1.5; }
          code { font-size: 12px; opacity: .6; word-break: break-all; }
        </style></head>
        <body><main><h1>\(esc(title))</h1><p>\(esc(message))</p><code>\(esc(url?.absoluteString ?? ""))</code></main></body></html>
        """
    }
}
