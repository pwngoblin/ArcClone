import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public private(set) var paths: AppPaths!
    private var registry: ScriptRegistry!
    private var factory: WebViewFactory!
    private var assistant: Assistant!
    private var sessionStore: SessionStore!
    private(set) var history: History!
    private(set) var siteSettings: SiteSettings!
    private var historyWindow: HistoryWindowController?
    private let historyMenuDelegate = HistoryMenuDelegate()
    private var windows: [BrowserWindowController] = []
    private var settingsWindow: SettingsWindowController?
    private var saveScheduled = false

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        paths = AppPaths.resolve()
        Log.app.info("Resources at \(self.paths.root.path, privacy: .public)")
        NSApp.mainMenu = MainMenu.build()
        AppearanceStyle.applyAppAppearance()
        Task { await launch() }
    }

    private func launch() async {
        // Packaged builds refuse to run modified code or resources (e.g. edited injection scripts).
        if AppInfo.isPackaged, let problem = await CodeIntegrity.verify(bundleAt: Bundle.main.bundleURL) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "ArcClone has been modified and can't be opened"
            alert.informativeText = "\(problem)\n\nDelete this copy and reinstall ArcClone from the official release."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        do {
            registry = try ScriptRegistry(manifestURL: paths.injectionManifest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "ArcClone could not load its content scripts"
            alert.informativeText = "\(error)\n\nLooked in \(paths.injections.path). Set ARCCLONE_ROOT to the repository root."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        siteSettings = SiteSettings(directory: ProcessInfo.processInfo.arguments.contains("--self-test") ? nil : paths.applicationSupport)
        await siteSettings.load()
        factory = WebViewFactory(registry: registry, siteSettings: siteSettings)
        assistant = Assistant(configuration: .fromPreferences())
        sessionStore = SessionStore(directory: paths.applicationSupport)
        // The self-test must not leave its fixture pages in the user's real history.
        let isSelfTest = ProcessInfo.processInfo.arguments.contains("--self-test")
        history = History(directory: isSelfTest ? nil : paths.applicationSupport)
        await history.load()
        historyMenuDelegate.history = history
        NSApp.mainMenu?.item(withTitle: "History")?.submenu?.delegate = historyMenuDelegate

        let controller = makeWindow()
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            controller.showWindowCentered()
            SelfTest.run(window: controller, assistant: assistant)
            return
        }
        let args = ProcessInfo.processInfo.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if Preferences.restoresSession, let session = await sessionStore.load(), !session.tabs.isEmpty {
            controller.tabs.restore(session)
        }
        for arg in args {
            if let url = Preferences.urlResolver.resolve(arg) { controller.tabs.create(url: url) }
        }
        if controller.tabs.tabs.isEmpty {
            controller.tabs.create(url: Preferences.homepage)
        }
        controller.showWindowCentered()
        NSApp.activate()
    }

    /// The encrypted session save is async, so quitting waits for it.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        assistant?.cancelAll()
        guard let primary = primaryWindow, let sessionStore else { return .terminateNow }
        let session = primary.tabs.session
        Task {
            await sessionStore.save(session)
            if Preferences.flag(Preferences.Key.clearHistoryOnQuit, default: false) { history?.clear() }
            await history?.flush()
            if Preferences.flag(Preferences.Key.clearWebsiteDataOnQuit, default: false) {
                // Cookies, storage and caches are written by WebKit unencrypted; don't leave them behind.
                await factory.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc public func clearBrowsingData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing data?"
        alert.informativeText = "This removes your browsing history, cookies, caches, site storage, the saved session and the assistant's context. Open tabs stay open, and you'll be signed out of websites."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await factory.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            await sessionStore.clear()
            history.clear()
            await history.flush()
            assistant.context.reset()
            windows.forEach { $0.tabs.clearRecentlyClosed() }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(makeDefaultBrowser(_:)) else { return true }
        return DefaultBrowser.isAvailable && !DefaultBrowser.isDefault
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        let target = primaryWindow ?? makeWindow()
        for url in urls {
            if url.isFileURL { target.tabs.openFile(url) } else { target.tabs.create(url: url) }
        }
        target.showWindow(nil)
    }

    /// The saved session belongs to the first regular (non-private) window.
    private var primaryWindow: BrowserWindowController? { windows.first { !$0.isPrivate } }

    func openInNewWindow(_ url: URL, isPrivate: Bool) {
        let controller = makeWindow(isPrivate: isPrivate)
        controller.tabs.create(url: url)
        controller.showWindowCentered()
    }

    @objc public func newPrivateWindow(_ sender: Any?) {
        let controller = makeWindow(isPrivate: true)
        controller.tabs.create(url: nil)
        controller.showWindowCentered()
        controller.newTab(nil)
    }

    /// File > Open File…: the panel grants sandbox access to exactly the chosen files.
    @objc public func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, UTType("public.xhtml") ?? .html, .webArchive, .pdf, .plainText, .svg, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to open in ArcClone"
        guard panel.runModal() == .OK else { return }
        let target = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? primaryWindow ?? makeWindow()
        panel.urls.forEach { target.tabs.openFile($0) }
        target.showWindow(nil)
    }

    @objc public func newWindow(_ sender: Any?) {
        let controller = makeWindow()
        controller.tabs.create(url: nil)
        controller.showWindowCentered()
        controller.newTab(nil)
    }

    @objc public func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(siteSettings: siteSettings,
                                                      clearBrowsingData: { [weak self] in self?.clearBrowsingData(nil) },
                                                      onAgentSettingsChanged: { [weak self] in self?.assistant.reconfigure(.fromPreferences()) })
        }
        settingsWindow?.present()
    }

    @objc public func makeDefaultBrowser(_ sender: Any?) {
        DefaultBrowser.makeDefault { error in
            if let error { NSApp.presentError(error) }
        }
    }

    @objc public func showHistory(_ sender: Any?) {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(history: history) { [weak self] url, newTab in self?.openFromHistory(url, newTab: newTab) }
        }
        historyWindow?.present()
    }

    /// History opens pages in the frontmost regular window (never a private one).
    func openFromHistory(_ url: URL, newTab: Bool) {
        let target = primaryWindow ?? makeWindow()
        target.open(url, newTab: newTab || target.tabs.active == nil)
        target.showWindow(nil)
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openFromHistory(url, newTab: true)
    }

    @objc public func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    private func makeWindow(isPrivate: Bool = false) -> BrowserWindowController {
        // Each private window gets its own in-memory data store: no cookies or caches touch disk,
        // and private windows can't see each other's sessions.
        let factory = isPrivate
            ? WebViewFactory(registry: registry, dataStore: .nonPersistent(), siteSettings: siteSettings, savesSiteChanges: false)
            : self.factory!
        let controller = BrowserWindowController(factory: factory, assistant: assistant, history: isPrivate ? nil : history, isPrivate: isPrivate)
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            if self.primaryWindow === closed {
                let session = closed.tabs.session
                Task { await self.sessionStore.save(session) }
            }
            self.windows.removeAll { $0 === closed }
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSave() }
        windows.append(controller)
        return controller
    }

    /// The first window's tabs are the persisted session (matching Arc's single-sidebar model).
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.saveScheduled = false
            guard let primary = self.primaryWindow, let sessionStore = self.sessionStore else { return }
            await sessionStore.save(primary.tabs.session)
        }
    }
}

/// Fills the History menu with recently visited pages each time it opens.
@MainActor
final class HistoryMenuDelegate: NSObject, NSMenuDelegate {
    weak var history: History?
    private static let tag = 4_200

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)
        guard let recent = history?.recent(12), !recent.isEmpty else { return }
        let header = NSMenuItem.sectionHeader(title: "Recently Visited")
        header.tag = Self.tag
        menu.addItem(header)
        for visit in recent {
            let title = visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(AppDelegate.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = visit.url
            item.toolTip = visit.url.absoluteString
            item.tag = Self.tag
            menu.addItem(item)
        }
    }
}
