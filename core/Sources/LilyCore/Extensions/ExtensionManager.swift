import AppKit
import Observation
import WebKit

/// The macOS 15.4+ extension runtime: runs the library's verified, pinned extensions through
/// WebKit's extension controller (content scripts, background, popups, chrome.* APIs, storage).
/// WebKit's extension types are main-thread only, so this lives on the main actor; file work
/// stays on `ExtensionActor` in `ExtensionLibrary`. Extensions never run in private windows and
/// can't reach Lily's page bridge, which lives in a separate content world. Native messaging
/// is refused cleanly (`NativeMessagingHostManager`).
@available(macOS 15.4, *)
@MainActor @Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    let library: ExtensionLibrary
    let controller = WKWebExtensionController(configuration: .default())
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// `chrome.notifications`, which WebKit lacks, through macOS notifications.
    @ObservationIgnored let notifications = ExtensionNotifications()
    /// How many of each extension's errors have been logged.
    @ObservationIgnored private var loggedErrors: [String: Int] = [:]
    @ObservationIgnored private var errorObserver: NSObjectProtocol?
    /// Window lookup for the extension APIs (tabs.query, windows.getAll).
    @ObservationIgnored var windows: () -> [BrowserWindowController] = { [] }
    @ObservationIgnored var focusedWindow: () -> BrowserWindowController? = { nil }
    @ObservationIgnored var openTab: (URL?, Bool) -> Tab? = { _, _ in nil }

    init(library: ExtensionLibrary) {
        self.library = library
        super.init()
        controller.delegate = self
        library.onReadyChange = { [weak self] in self?.sync() }
        notifications.isApproved = { [weak self] id in
            self?.library.installed.first { $0.id == id }?.grantedPermissions.contains("notifications") == true
        }
        notifications.context = { [weak self] id in self?.contexts[id] }
        errorObserver = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: nil, queue: .main) { [weak self] note in
            guard let context = note.object as? WKWebExtensionContext else { return }
            MainActor.assumeIsolated { self?.logErrors(context) }
        }
    }

    /// Loads newly ready extensions and unloads removed or disabled ones.
    func sync() {
        let ready = Set(library.ready.map(\.id))
        for id in contexts.keys where !ready.contains(id) { unload(id) }
        for entry in library.ready where contexts[entry.id] == nil { Task { await load(entry) } }
    }

    private func load(_ entry: ExtensionLibrary.Entry) async {
        guard contexts[entry.id] == nil, let record = library.installed.first(where: { $0.id == entry.id }) else { return }
        do {
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: entry.folder))
            guard contexts[entry.id] == nil, library.entry(entry.id) != nil else { return }
            context.uniqueIdentifier = entry.id
            context.isInspectable = WebInspector.isEnabled
            // Only what the user approved at install time.
            for name in record.grantedPermissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name)) }
            // The worker shim reaches Lily's notifications through native messaging, which WebKit
            // exposes only when granted. The extension's own code sees the API too, but Lily answers
            // only its notifications name (already approved) and refuses every other one.
            if record.grantedPermissions.contains("notifications") { context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging) }
            for pattern in record.grantedPatterns {
                if let match = try? WKWebExtension.MatchPattern(string: pattern) { context.setPermissionStatus(.grantedExplicitly, for: match) }
            }
            try controller.load(context)
            contexts[entry.id] = context
            logErrors(context)
            for window in windows() { window.registerWithExtensions(controller) }
        } catch {
            Log.extensions.error("Loading an extension failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func unload(_ id: String) {
        if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
        notifications.removeAll(for: id)
        loggedErrors[id] = nil
    }

    // MARK: Toolbar

    func hasOptions(_ id: String) -> Bool { contexts[id]?.optionsPageURL != nil }

    /// Web developer features switched: extension pages become (or stop being) inspectable.
    func applyInspectable() {
        contexts.values.forEach { $0.isInspectable = WebInspector.isEnabled }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        _ = openTab(url, true)
    }

    /// Runs the extension's toolbar action for the active tab (may present its popup).
    func performAction(_ id: String) {
        guard let context = contexts[id] else { return }
        let tab = focusedWindow()?.tabs.active
        Log.extensions.debug("Action clicked: popup \(context.action(for: tab)?.presentsPopup == true ? "set" : "not set", privacy: .public)")
        context.performAction(for: tab)
    }

    /// An extension's errors (its scripts' exceptions, failed API calls, manifest problems), at
    /// debug level: not kept on disk, visible with `log stream --level debug` while reproducing a
    /// problem. They describe the extension's code, so they're shown as is.
    private func logErrors(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        let errors = context.errors
        let seen = loggedErrors[id] ?? 0
        guard errors.count > seen else { loggedErrors[id] = errors.count; return }
        let name = context.webExtension.displayName ?? "extension"
        for error in errors[seen...] {
            Log.extensions.debug("\(name, privacy: .public) error: \(String(error.localizedDescription.prefix(500)), privacy: .public)")
        }
        loggedErrors[id] = errors.count
    }

    func actionIcon(_ id: String) -> NSImage? {
        guard let context = contexts[id] else { return nil }
        return context.action(for: focusedWindow()?.tabs.active)?.icon(for: CGSize(width: 18, height: 18))
            ?? context.webExtension.icon(for: CGSize(width: 18, height: 18))
    }

    /// The action's badge for the active tab ("3", "ON"), if any.
    func badge(_ id: String) -> String? {
        let text = contexts[id]?.action(for: focusedWindow()?.tabs.active)?.badgeText ?? ""
        return text.isEmpty ? nil : String(text.prefix(4))
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows()
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedWindow()
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        openTab(configuration.url, configuration.shouldBeActive)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        if let url = extensionContext.optionsPageURL { _ = openTab(url, true) }
    }

    /// `runtime.sendNativeMessage`: Lily's own notifications name, or refused at once, so the
    /// extension falls back to its own flows.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == ExtensionNotifications.applicationIdentifier {
            return try await notifications.handle(message, from: extensionContext)
        }
        if applicationIdentifier == ExtensionConsole.applicationIdentifier {
            return try ExtensionConsole.handle(message, extensionName: extensionContext.webExtension.displayName ?? "extension",
                                               enabled: WebInspector.isEnabled)
        }
        throw await NativeMessagingHostManager.shared.request(application: applicationIdentifier, extensionName: extensionContext.webExtension.displayName ?? "extension")
    }

    /// `runtime.connectNative`: refused at once rather than left hanging.
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext) async throws {
        if port.applicationIdentifier == ExtensionNotifications.applicationIdentifier {
            return try notifications.connect(port, from: extensionContext)
        }
        throw await NativeMessagingHostManager.shared.request(application: port.applicationIdentifier, extensionName: extensionContext.webExtension.displayName ?? "extension")
    }

    /// Runtime permission requests are asked, never granted silently.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let names = permissions.map { ExtensionLibrary.describe($0.rawValue) }.sorted()
        return confirm("“\(extensionContext.webExtension.displayName ?? "An extension")” wants to:", names) ? (permissions, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let hosts = urls.compactMap(\.host).sorted()
        return confirm("Allow “\(extensionContext.webExtension.displayName ?? "an extension")” to read and change data on:", hosts) ? (urls, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let patterns = matchPatterns.map(\.string).sorted()
        return confirm("Allow “\(extensionContext.webExtension.displayName ?? "an extension")” to read and change data on:", patterns) ? (matchPatterns, nil) : ([], nil)
    }

    /// Shows an extension's popup under the toolbar's Extensions button.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        // Without a window to show it in, the preloaded popup is closed rather than left loaded.
        guard action.presentsPopup, let window = focusedWindow() else {
            Log.extensions.debug("Popup not shown: \(action.presentsPopup ? "no window" : "no popup", privacy: .public)")
            action.closePopup()
            return
        }
        Log.extensions.debug("Showing popup")
        window.presentExtensionPopup(action)
    }

    private func confirm(_ title: String, _ items: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = items.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
