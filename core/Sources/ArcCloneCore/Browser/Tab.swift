import WebKit

@MainActor
public protocol TabDelegate: AnyObject {
    func tabDidChange(_ tab: Tab)
    func tab(_ tab: Tab, requestsNewTabWith request: URLRequest, inBackground: Bool)
    func tabRequestsClose(_ tab: Tab)
    func tabDidStartDownload(_ tab: Tab)
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
    public private(set) var faviconURL: URL?
    public private(set) var themeColor: String?
    public private(set) var lastSelection: String?
    public private(set) var youtubeVideoID: String?
    public var isPinned = false
    /// The space this tab belongs to (TabStore assigns it).
    public var spaceID = UUID()
    public private(set) var lastActivated = Date()

    private let bridge: ScriptMessageBridge
    private let contentWorld: WKContentWorld
    private var observations: [NSKeyValueObservation] = []
    private var crashTimes: [Date] = []
    private var pendingURL: URL?
    /// A local file this tab holds sandbox access to (from a security-scoped bookmark or Open panel).
    private var securityScopedURL: URL?
    /// The original http:// URL while its HTTPS-First upgrade is loading.
    private var upgradedFrom: URL?
    private var dialogCount = 0
    private var dialogsSuppressed = false
    /// A data: URL this app chose to load (typed, history); pages may not navigate the tab to data: URLs.
    private var allowedDataURL: URL?
    private var isDiscarded = false
    let siteSettings: SiteSettings?
    let adBlocker: AdBlocker?

    public init(id: UUID = UUID(), factory: WebViewFactory, router: IPCRouter, url: URL?, pinned: Bool = false) {
        self.id = id
        self.isPinned = pinned
        self.contentWorld = factory.registry.contentWorld
        self.siteSettings = factory.siteSettings
        self.adBlocker = factory.adBlocker
        let tabID = id
        self.bridge = ScriptMessageBridge(name: ScriptRegistry.messageHandlerName,
                                          contentWorld: factory.registry.contentWorld,
                                          router: router) { message in
            // The origin comes from WebKit's view of the frame, not from anything the page says.
            let origin = message.frameInfo.securityOrigin
            return .page(tabID: tabID, isMainFrame: message.frameInfo.isMainFrame,
                         url: IPCSource.originURL(protocol: origin.protocol, host: origin.host, port: origin.port))
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
        adBlocker?.forget(webView.configuration.userContentController)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        observations.removeAll()
        bridge.detach(from: webView.configuration.userContentController)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        isDiscarded = true
    }

    // MARK: Navigation

    public func load(_ url: URL) {
        if url.scheme == "data" { allowedDataURL = url }
        if url.isFileURL {
            // Least privilege: WebContent may read this file only, not its whole folder.
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }
    public func reload() { webView.reload() }
    public func stop() { webView.stopLoading() }

    public func markActivated() {
        lastActivated = Date()
        wake()
    }

    // MARK: Page change detection

    private var recheckTask: Task<Void, Never>?

    /// The page scripts no longer poll for single-page-app navigations; when WebKit reports a URL
    /// change we ask them, once, to re-read the page (debounced to coalesce redirect bursts).
    func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, !self.isSleeping else { return }
            _ = try? await self.callInjection("page.recheck", timeout: 5)
            if let host = self.webView.url?.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") {
                _ = try? await self.callInjection("youtube.recheck", timeout: 5)
            }
        }
    }

    // MARK: Sleeping (memory and energy)

    /// True while the page is unloaded to save memory; the tab still shows its title and icon.
    public private(set) var isSleeping = false
    /// Back/forward list and scroll position captured when the tab went to sleep.
    private var sleepState: Any?

    /// Unloads the page (its web content process can exit), keeping enough to restore it exactly.
    func sleep() {
        guard !isSleeping, let url, url.scheme == "https" || url.scheme == "http" else { return }
        sleepState = webView.interactionState
        isSleeping = true
        isLoading = false
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        notify()
    }

    /// Restores the page as it was (history and scroll position) when the tab is used again.
    func wake() {
        guard isSleeping else { return }
        isSleeping = false
        if let sleepState {
            webView.interactionState = sleepState
        } else if let url {
            load(url)
        }
        sleepState = nil
        notify()
    }

    /// Media, camera and microphone keep a tab awake.
    func isBusy() async -> Bool {
        if isLoading || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

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
                    continuation.resume(throwing: IPCError("injection_failed", Sanitize.errorMessage(error)))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard gate.open() else { return }
                continuation.resume(throwing: IPCError("timeout", "\(name) timed out"))
            }
        }
        // Results come from a page we don't trust: refuse absurd sizes before parsing.
        guard raw.utf8.count <= 4 * 1024 * 1024 else { throw IPCError("too_large", "\(name) returned too much data") }
        let reply = try JSONValue.parse(raw)
        if reply["ok"]?.bool == true { return reply["result"] ?? .null }
        let err = reply["error"]
        throw IPCError(err?["code"]?.string ?? "injection_error", err?["message"]?.string ?? "Injection call failed")
    }

    // MARK: Page events (page -> native), applied by the window's page handlers

    func applyMetadata(_ metadata: PagePayload.Metadata) {
        if let favicon = metadata.favicon { faviconURL = favicon }
        themeColor = metadata.themeColor
        if let t = metadata.title, t != title { title = t }
        notify()
    }

    // MARK: Site settings

    /// Zoom and color scheme for the committed page's site.
    func applySiteAppearance() {
        guard let siteSettings, url?.isFileURL != true else { return }
        let zoom = siteSettings.zoom(for: webView.url)
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
        switch siteSettings.darkMode(for: webView.url) {
        case .standard: webView.appearance = nil
        case .dark, .forced: webView.appearance = NSAppearance(named: .darkAqua)
        case .light: webView.appearance = NSAppearance(named: .aqua)
        }
    }

    /// Force Dark: invert the page if it is still light after asking for its dark theme.
    func applyForcedDark() {
        guard let siteSettings else { return }
        let mode = siteSettings.darkMode(for: webView.url)
        Task { _ = try? await callInjection("darkMode.apply", ["mode": .string(mode.rawValue)], timeout: 5) }
        if let host = webView.url?.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let enabled = (adBlocker?.isEnabled ?? false) && !siteSettings.adsAllowed(for: webView.url)
            Task { _ = try? await callInjection("adblock.configure", ["enabled": .bool(enabled)], timeout: 5) }
        }
    }

    /// Re-applies everything after the user changes this site's settings.
    func siteSettingsDidChange() {
        applySiteAppearance()
        applyForcedDark()
    }

    /// Keeps sandbox access to a user-chosen file for as long as the tab shows it.
    func holdSecurityScope(_ url: URL) {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    /// Read-only, app-scoped bookmark so the file can be reopened after relaunch.
    var fileBookmark: Data? {
        guard let url, url.isFileURL else { return nil }
        return try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func applySelection(_ text: String?) {
        lastSelection = (text?.isEmpty ?? true) ? nil : text
    }

    func applyYouTubeVideo(_ id: String?) {
        youtubeVideoID = id
        notify()
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
                guard !tab.isSleeping else { return } // keep showing the page that went to sleep
                if let t = tab.webView.title, !t.isEmpty { tab.title = t }
                tab.notify()
            },
            watch(\.url) { tab in
                guard !tab.isSleeping else { return }
                tab.scheduleRecheck()
                if let u = tab.webView.url {
                    if tab.url?.host != u.host { tab.faviconURL = nil }
                    tab.url = u
                }
                tab.notify()
            },
            watch(\.isLoading) { tab in guard !tab.isSleeping else { return }; tab.isLoading = tab.webView.isLoading; tab.notify() },
            watch(\.fullscreenState) { tab in
                switch tab.webView.fullscreenState {
                case .inFullscreen:
                    let origin = tab.webView.url.flatMap { $0.host } ?? "This page"
                    FullscreenNotice.show(host: origin, on: tab.webView.window?.screen)
                case .exitingFullscreen, .notInFullscreen:
                    FullscreenNotice.hide()
                default:
                    break
                }
            },
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
                                              message: Sanitize.errorMessage(nsError),
                                              url: target),
                               baseURL: target)
    }
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // Top-level data: URLs from pages are a phishing vector (a fake login page with no real origin).
        if navigationAction.request.url?.scheme == "data", navigationAction.targetFrame?.isMainFrame ?? true,
           navigationAction.request.url != allowedDataURL {
            Log.web.info("Blocked a page-initiated top-level data: navigation")
            return (.cancel, preferences)
        }
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
        // Per-site JavaScript and ad blocking, decided before the page starts loading.
        if navigationAction.targetFrame?.isMainFrame ?? true {
            let target = navigationAction.request.url
            if let siteSettings { preferences.allowsContentJavaScript = siteSettings.allowsJavaScript(for: target) }
            adBlocker?.configure(webView.configuration.userContentController, adsAllowed: siteSettings?.adsAllowed(for: target) ?? false)
        }
        return (.allow, preferences)
    }

    /// The HTTPS-First upgrade failed: explain the risk and let the user continue over HTTP.
    private func offerHTTPFallback(to url: URL, error: NSError) {
        guard let host = url.host?.lowercased() else { return }
        let alert = NSAlert()
        alert.messageText = "“\(host)” doesn't support a secure connection"
        alert.informativeText = "Anyone on your network could see or change what you send to and receive from this site over HTTP.\n\n\(Sanitize.errorMessage(error))"
        alert.addButton(withTitle: "Continue to HTTP")
        alert.addButton(withTitle: "Cancel")
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                HTTPSFirst.allowedHTTPHosts.insert(host)
                self.load(url)
            } else {
                self.webView.loadHTMLString(ErrorPage.html(title: "Secure connection unavailable", message: Sanitize.errorMessage(error), url: url),
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
        DownloadManager.shared.track(download)
        delegate?.tabDidStartDownload(self)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
        delegate?.tabDidStartDownload(self)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pendingURL = webView.url
        youtubeVideoID = nil
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        upgradedFrom = nil
        dialogCount = 0
        dialogsSuppressed = false
        applySiteAppearance()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyForcedDark()
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
        Log.web.error("Web content process terminated for tab \(self.id.uuidString, privacy: .public) (\(self.crashTimes.count, privacy: .public) in last minute)")
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
        _ = await presentDialog(message, frame: frame, buttons: ["OK"])
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presentDialog(message, frame: frame, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(string: String((defaultText ?? "").prefix(1_000)))
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let response = await presentDialog(prompt, frame: frame, buttons: ["OK", "Cancel"], accessory: field)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// JavaScript dialogs, hardened: titled with the frame's real security origin (not a URL the page
    /// controls), text capped, shown as a sheet on this window only, and after the third dialog the
    /// user can block the rest for this page.
    private func presentDialog(_ message: String, frame: WKFrameInfo, buttons: [String], accessory: NSView? = nil) async -> NSApplication.ModalResponse {
        if dialogsSuppressed { return .alertSecondButtonReturn }
        let origin = frame.securityOrigin
        let alert = NSAlert()
        alert.messageText = Self.dialogTitle(origin: IPCSource.originURL(protocol: origin.protocol, host: origin.host, port: origin.port))
        alert.informativeText = Self.dialogText(message)
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        dialogCount += 1
        alert.showsSuppressionButton = dialogCount > 2
        alert.suppressionButton?.title = "Don't allow this page to show more dialogs"
        guard let window = webView.window else { return alert.runModal() }
        let response = await alert.beginSheetModal(for: window)
        if alert.suppressionButton?.state == .on { dialogsSuppressed = true }
        return response
    }

    nonisolated static func dialogTitle(origin: URL?) -> String {
        guard let host = origin?.host, !host.isEmpty else { return "This page says:" }
        return "\(host) says:"
    }

    nonisolated static func dialogText(_ message: String) -> String {
        let cleaned = String(message.unicodeScalars.filter { !Sanitize.isInvisibleControl($0) }.map(Character.init))
        return cleaned.count > 1_000 ? String(cleaned.prefix(1_000)) + "…" : cleaned
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
        guard let siteSettings else { return .prompt }
        let site = IPCSource.originURL(protocol: origin.protocol, host: origin.host, port: origin.port)
        var asked: [SiteSettings.Permission] = []
        if type == .camera || type == .cameraAndMicrophone { asked.append(siteSettings.permission(\.camera, for: site)) }
        if type == .microphone || type == .cameraAndMicrophone { asked.append(siteSettings.permission(\.microphone, for: site)) }
        if asked.contains(.deny) { return .deny }
        return asked.allSatisfy { $0 == .allow } ? .grant : .prompt
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
            Sanitize.html(s)
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(esc(title))</title>
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
