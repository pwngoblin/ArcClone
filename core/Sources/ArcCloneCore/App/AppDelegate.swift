import AppKit
import WebKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var paths: AppPaths!
    private var registry: ScriptRegistry!
    private var factory: WebViewFactory!
    private var agent: AgentService!
    private var sessionStore: SessionStore!
    private var windows: [BrowserWindowController] = []
    private var saveScheduled = false

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        paths = AppPaths.resolve()
        Log.app.info("Resources at \(self.paths.root.path, privacy: .public)")
        NSApp.mainMenu = MainMenu.build()

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
        factory = WebViewFactory(registry: registry)
        agent = AgentService(paths: paths)
        agent.start()
        sessionStore = SessionStore(directory: paths.applicationSupport)

        let controller = makeWindow()
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            controller.showWindowCentered()
            SelfTest.run(window: controller, agent: agent)
            return
        }
        let args = ProcessInfo.processInfo.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let session = sessionStore.load(), !session.tabs.isEmpty {
            controller.tabs.restore(session)
        }
        for arg in args {
            if let url = URLResolver().resolve(arg) { controller.tabs.create(url: url) }
        }
        if controller.tabs.tabs.isEmpty {
            controller.tabs.create(url: URL(string: "https://www.youtube.com"))
        }
        controller.showWindowCentered()
        NSApp.activate()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        agent?.shutdown()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    public func application(_ application: NSApplication, open urls: [URL]) {
        let target = windows.first ?? makeWindow()
        urls.forEach { target.tabs.create(url: $0) }
        target.showWindow(nil)
    }

    @objc public func newWindow(_ sender: Any?) {
        let controller = makeWindow()
        controller.tabs.create(url: nil)
        controller.showWindowCentered()
        controller.newTab(nil)
    }

    private func makeWindow() -> BrowserWindowController {
        let controller = BrowserWindowController(factory: factory, agent: agent, paths: paths)
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            if self.windows.first === closed { self.sessionStore.save(closed.tabs.session) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveSession()
            }
        }
    }

    private func saveSession() {
        guard let primary = windows.first, let sessionStore else { return }
        sessionStore.save(primary.tabs.session)
    }
}
