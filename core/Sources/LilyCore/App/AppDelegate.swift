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
    private(set) var formDrafts: FormDrafts!
    private(set) var siteSettings: SiteSettings!
    private(set) var adBlocker: AdBlocker!
    /// Installed extensions (every macOS version) and their runtime: `ExtensionManager` on macOS
    /// 15.4+, `ExtensionScriptInjector` (page scripts only) before that.
    private(set) var extensionLibrary: ExtensionLibrary?
    private(set) var extensionRuntime: AnyObject?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var historyWindow: HistoryWindowController?
    private let historyMenuDelegate = HistoryMenuDelegate()
    private(set) var bookmarks: Bookmarks!
    private let bookmarksMenuDelegate = BookmarksMenuDelegate()
    private var migrationAccess: MigrationAccess?
    private var migrationWindow: MigrationWindowController?
    private var windows: [BrowserWindowController] = []
    /// Links from other apps that arrive while Lily is still starting (a cold launch from a link)
    /// wait here until the windows can be made.
    private var launched = false
    private var pendingLinks: [URL] = []
    /// Where the next Little Lily window goes, so several cascade instead of stacking.
    private var littleCascade: NSPoint?
    private var settingsWindow: SettingsWindowController?
    private var saveScheduled = false

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        paths = AppPaths.resolve()
        Log.app.info("Resources at \(self.paths.root.path, privacy: .public)")
        MainMenu.disableSystemItems()
        NSApp.mainMenu = MainMenu.build()
        MainMenu.updateDevelopMenu()
        AppearanceStyle.applyAppAppearance()
        watchMemoryPressure()
        Task { await launch() }
    }

    /// When macOS runs low on memory, unload every background tab that can sleep.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                Log.app.info("Memory pressure: putting background tabs to sleep")
                self?.windows.forEach { $0.sleepBackgroundTabs() }
            }
        }
        source.resume()
        memoryPressure = source
    }

    private func launch() async {
        // Packaged builds refuse to run modified code or resources (e.g. edited injection scripts).
        if AppInfo.isPackaged, let problem = await CodeIntegrity.verify(bundleAt: Bundle.main.bundleURL) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Lily has been modified and can't be opened"
            alert.informativeText = "\(problem)\n\nDelete this copy and reinstall Lily from the official release."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        do {
            registry = try ScriptRegistry(manifestURL: paths.injectionManifest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Lily could not load its content scripts"
            Log.app.error("Content scripts failed to load from \(self.paths.injections.path, privacy: .private): \(String(describing: error), privacy: .private)")
            // Packaged builds don't reveal paths; development builds explain how to fix the setup.
            alert.informativeText = AppInfo.isPackaged
                ? "The app's resources are missing or damaged. Reinstall Lily."
                : "\(Sanitize.errorMessage(error))\n\nSet LILY_ROOT to the repository root."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        siteSettings = SiteSettings(directory: ProcessInfo.processInfo.arguments.contains("--self-test") ? nil : paths.applicationSupport)
        await siteSettings.load()
        adBlocker = AdBlocker(directory: ProcessInfo.processInfo.arguments.contains("--self-test") ? nil : paths.applicationSupport)
        await adBlocker.prepare()
        factory = WebViewFactory(registry: registry, siteSettings: siteSettings, adBlocker: adBlocker)
        if !ProcessInfo.processInfo.arguments.contains("--self-test") {
            let workerShim = try? Data(contentsOf: paths.injections.appendingPathComponent("extension-worker-compat.js"))
            // Without it, Chrome-built extensions whose background uses missing APIs install but never start.
            if workerShim == nil { Log.extensions.error("Extension worker shim missing from the app's resources") }
            let library = ExtensionLibrary(directory: paths.applicationSupport, workerShim: workerShim)
            extensionLibrary = library
            startExtensionRuntime(library)
            Task { await library.loadAll() }
        }
        assistant = Assistant(configuration: .fromPreferences())
        sessionStore = SessionStore(directory: paths.applicationSupport)
        // The self-test must not leave its fixture pages in the user's real history.
        let isSelfTest = ProcessInfo.processInfo.arguments.contains("--self-test")
        history = History(directory: isSelfTest ? nil : paths.applicationSupport)
        // Kept site icons follow history: whatever history forgets, its icons go too.
        await FaviconLoader.shared.load(directory: isSelfTest ? nil : paths.applicationSupport)
        history.onForget = { FaviconLoader.shared.forget($0) }
        await history.load()
        formDrafts = FormDrafts(directory: isSelfTest ? nil : paths.applicationSupport)
        await formDrafts.load()
        historyMenuDelegate.history = history
        NSApp.mainMenu?.item(withTitle: "History")?.submenu?.delegate = historyMenuDelegate
        bookmarks = Bookmarks(directory: isSelfTest ? nil : paths.applicationSupport)
        await bookmarks.load()
        bookmarksMenuDelegate.bookmarks = bookmarks
        NSApp.mainMenu?.item(withTitle: "Bookmarks")?.submenu?.delegate = bookmarksMenuDelegate
        migrationAccess = MigrationAccess(directory: isSelfTest ? nil : paths.applicationSupport)

        let controller = makeWindow()
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            controller.showWindowCentered()
            launched = true
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
        launched = true
        let waiting = pendingLinks
        pendingLinks = []
        if !waiting.isEmpty { open(waiting) }
    }

    /// The encrypted session save is async, so quitting waits for it.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        assistant?.cancelAll()
        guard let primary = primaryWindow, let sessionStore else { return .terminateNow }
        let session = primary.tabs.session
        Task {
            await sessionStore.save(session)
            if Preferences.flag(Preferences.Key.clearHistoryOnQuit, default: false) {
                history?.clear()
                formDrafts?.removeAll()
            }
            await history?.flush()
            await formDrafts?.flush()
            await bookmarks?.flush()
            if Preferences.flag(Preferences.Key.clearWebsiteDataOnQuit, default: false) {
                // Cookies, storage and caches are written by WebKit unencrypted; don't leave them behind
                // (every space's own store included).
                await factory.removeAllWebsiteData()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc public func clearBrowsingData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing data?"
        alert.informativeText = "This removes your browsing history, cookies, caches, site storage, the saved session, saved typed text and the assistant's context. Open tabs stay open, and you'll be signed out of websites."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await factory.removeAllWebsiteData()
            await sessionStore.clear()
            history.clear()
            await history.flush()
            formDrafts.removeAll()
            await formDrafts.flush()
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
        guard launched else { return pendingLinks += urls }
        open(urls)
    }

    /// Links from other apps: web pages in Little Lily (when that's on), files and everything else
    /// as tabs in the main window.
    private func open(_ urls: [URL]) {
        let little = Preferences.flag(Preferences.Key.linksOpenInLittleLily, default: true)
        var target: BrowserWindowController?
        for url in urls {
            if little, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                openLittle(url)
                continue
            }
            let main = target ?? primaryWindow ?? makeWindow()
            target = main
            if url.isFileURL { main.tabs.openFile(url) } else { main.tabs.create(url: url) }
        }
        target?.showWindow(nil)
    }

    /// The saved session belongs to the first regular window (not private, not Little Lily).
    private var primaryWindow: BrowserWindowController? { windows.first { !$0.isPrivate && !$0.isLittle } }

    /// The main window for Little Lily to hand pages to; made (empty) if there isn't one.
    private func mainWindowForLittle() -> BrowserWindowController {
        if let primary = primaryWindow { return primary }
        let controller = makeWindow()
        controller.showWindowCentered()
        return controller
    }

    /// A Little Lily window for `url`, or the one already showing it, brought forward.
    func openLittle(_ url: URL) {
        if let open = windows.first(where: { $0.isLittle && $0.tabs.active?.url == url }) {
            open.showWindow(nil)
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = makeWindow(style: .little)
        controller.tabs.create(url: url)
        showLittle(controller)
    }

    /// File → New Little Lily Window (⌥⌘N): an empty one, with the address bar open.
    @objc public func newLittleLilyWindow(_ sender: Any?) {
        let controller = makeWindow(style: .little)
        showLittle(controller)
        controller.model.presentCommandBar(newTab: true)
    }

    private func showLittle(_ controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        if let point = littleCascade {
            littleCascade = window.cascadeTopLeft(from: point)
        } else {
            window.center()
            littleCascade = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        }
        controller.showWindow(nil)
        NSApp.activate()
    }

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
        panel.message = "Choose files to open in Lily"
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

    private func startExtensionRuntime(_ library: ExtensionLibrary) {
        if #available(macOS 15.4, *) {
            let manager = ExtensionManager(library: library)
            manager.windows = { [weak self] in self?.windows.filter { !$0.isPrivate } ?? [] }
            manager.focusedWindow = { [weak self] in
                (NSApp.keyWindow?.windowController as? BrowserWindowController).flatMap { $0.isPrivate ? nil : $0 } ?? self?.primaryWindow
            }
            manager.openTab = { [weak self] url, active in
                // chrome.tabs.create from a Little Lily window opens in the main window.
                guard let focused = manager.focusedWindow() ?? self?.primaryWindow,
                      let target = focused.isLittle ? self?.mainWindowForLittle() : focused else { return nil }
                return target.tabs.create(url: url, activate: active)
            }
            extensionRuntime = manager
            factory.extensionController = manager.controller
        } else {
            do {
                let injector = try ExtensionScriptInjector(library: library, shimURL: paths.injections.appendingPathComponent("extension-compat.js"))
                extensionRuntime = injector
                factory.extensionScripts = injector
            } catch {
                Log.extensions.error("Extension compatibility shim missing; extensions won't run")
            }
        }
    }

    @objc public func showExtensionsSettings(_ sender: Any?) {
        showSettings(sender)
        settingsWindow?.select(pane: "Extensions")
    }

    @objc public func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(siteSettings: siteSettings, adBlocker: adBlocker, extensionLibrary: extensionLibrary, extensionRuntime: extensionRuntime,
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

    /// File → Import from Another Browser…
    @objc public func showMigration(_ sender: Any?) {
        guard let migrationAccess else { return }
        if migrationWindow == nil {
            let model = MigrationModel(access: migrationAccess, destination: .init(bookmarks: bookmarks, history: history) { [weak self] in
                (self?.primaryWindow ?? self?.makeWindow())?.tabs
            })
            migrationWindow = MigrationWindowController(model: model)
        }
        migrationWindow?.present()
    }

    @objc func removeAllBookmarks(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove all \(bookmarks.linkCount.formatted()) bookmarks?"
        alert.informativeText = "This can't be undone. Your other browsers' bookmarks aren't affected."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { bookmarks.removeAll() }
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openFromHistory(url, newTab: true)
    }

    /// Settings → General → web developer features: the Develop menu, and every open page and
    /// extension page, follow at once.
    func webDeveloperFeaturesChanged() {
        MainMenu.updateDevelopMenu()
        windows.forEach { $0.applyWebInspector() }
        if #available(macOS 15.4, *) { (extensionRuntime as? ExtensionManager)?.applyInspectable() }
    }

    @objc public func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    private func makeWindow(isPrivate: Bool = false, style: BrowserWindowController.Style = .regular) -> BrowserWindowController {
        // Each private window gets its own in-memory data store: no cookies or caches touch disk,
        // and private windows can't see each other's sessions.
        let factory = isPrivate
            ? WebViewFactory(registry: registry, dataStore: .nonPersistent(), siteSettings: siteSettings, savesSiteChanges: false, adBlocker: adBlocker)
            : self.factory!
        let controller = BrowserWindowController(factory: factory, assistant: assistant, history: isPrivate ? nil : history,
                                                 isPrivate: isPrivate, style: style)
        controller.bookmarks = bookmarks
        controller.mainWindow = { [weak self] in self?.mainWindowForLittle() }
        controller.openLittle = { [weak self] url in self?.openLittle(url) }
        controller.formDrafts = isPrivate ? nil : formDrafts
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

/// Fills the Bookmarks menu with folders (as submenus) and links when it opens.
@MainActor
final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {
    weak var bookmarks: Bookmarks?
    private static let tag = 4_300
    private static let maxItemsPerMenu = 300

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)
        guard let root = bookmarks?.root, !root.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.tag
        menu.addItem(separator)
        for item in Self.items(root, depth: 0) {
            item.tag = Self.tag
            menu.addItem(item)
        }
    }

    static func items(_ nodes: [Bookmarks.Node], depth: Int) -> [NSMenuItem] {
        nodes.prefix(maxItemsPerMenu).map { node in
            let title = String((node.title.isEmpty ? (node.url?.host ?? "Untitled") : node.title).prefix(60))
            if let children = node.children {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu(title: title)
                if depth < 8 { Self.items(children, depth: depth + 1).forEach(submenu.addItem) }
                item.submenu = submenu
                return item
            }
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = node.url
            item.toolTip = node.url?.absoluteString
            return item
        }
    }
}
