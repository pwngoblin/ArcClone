import AppKit
import Observation
import WebKit

/// One installed extension as remembered between launches.
struct InstalledExtension: Codable, Identifiable, Equatable {
    var id: String               // WKWebExtensionContext.uniqueIdentifier
    var bookmark: Data           // read-only, app-scoped security-scoped bookmark to the folder or .zip
    var enabled: Bool
    var grantedPermissions: [String]
    var grantedPatterns: [String]
}

/// Web extensions (WebExtensions API, manifest v2/v3) loaded from a folder or .zip the user picks.
/// Every permission is shown and approved at install; extensions never run in private windows.
@available(macOS 15.4, *)
@MainActor @Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    @MainActor struct Loaded: Identifiable {
        let id: String
        let context: WKWebExtensionContext
        var name: String { context.webExtension.displayName ?? "Extension" }
        var version: String { context.webExtension.displayVersion ?? context.webExtension.version ?? "" }
        var summary: String { context.webExtension.displayDescription ?? "" }
        var icon: NSImage? { context.webExtension.icon(for: CGSize(width: 32, height: 32)) }
    }

    static let storageKey = "InstalledWebExtensions"
    let controller = WKWebExtensionController(configuration: .default())
    private(set) var loaded: [Loaded] = []
    private(set) var installed: [InstalledExtension] = []
    private(set) var lastError: String?
    @ObservationIgnored private var scopedURLs: [String: URL] = [:]
    /// Window lookup for the extension APIs (tabs.query, windows.getAll).
    @ObservationIgnored var windows: () -> [BrowserWindowController] = { [] }
    @ObservationIgnored var focusedWindow: () -> BrowserWindowController? = { nil }
    @ObservationIgnored var openTab: (URL?, Bool) -> Tab? = { _, _ in nil }

    /// The installed list decides what code runs in every page, so it is sealed (encrypted and
    /// authenticated with the Keychain key) instead of kept in UserDefaults, where any process able
    /// to write ArcClone's preferences could add an "extension".
    @ObservationIgnored private let file: SealedFile?

    init(directory: URL?, keys: KeyStore = KeychainKeyStore()) {
        file = directory.map {
            SealedFile(url: $0.appendingPathComponent("extensions.sealed"), keyName: "extensions", purpose: "dev.arcclone.extensions.v1", keys: keys)
        }
        super.init()
        controller.delegate = self
    }

    /// Reads the sealed list (migrating the old UserDefaults copy once) and loads enabled extensions.
    func loadAll() async {
        do {
            if let data = try await file?.read() { installed = try JSONDecoder().decode([InstalledExtension].self, from: data) }
        } catch {
            // Tampered or unreadable: load nothing rather than trust it.
            Log.app.error("Installed extensions list failed authentication; ignoring it")
            lastError = "The list of installed extensions couldn't be verified, so no extensions were loaded. Add them again."
            installed = []
        }
        if let legacy = UserDefaults.standard.data(forKey: Self.storageKey) {
            if installed.isEmpty, let old = try? JSONDecoder().decode([InstalledExtension].self, from: legacy) { installed = old }
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            save()
        }
        for record in installed where record.enabled { await load(record) }
    }

    // MARK: Install / remove

    /// Picks an unpacked extension folder or .zip, shows what it asks for, and installs it if approved.
    func install(presentingIn window: NSWindow?) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose an unpacked web extension folder (with manifest.json) or a .zip"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: url)
            guard confirmInstall(webExtension, window: window) else { return }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let context = WKWebExtensionContext(for: webExtension)
            let record = InstalledExtension(id: context.uniqueIdentifier, bookmark: bookmark, enabled: true,
                                            grantedPermissions: webExtension.requestedPermissions.map(\.rawValue),
                                            grantedPatterns: webExtension.allRequestedMatchPatterns.map(\.string))
            installed.removeAll { $0.id == record.id }
            installed.append(record)
            save()
            await load(record, context: context)
        } catch {
            lastError = "Couldn't install: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        save()
        if enabled { Task { await load(installed[index]) } } else { unload(id) }
    }

    func remove(_ id: String) {
        unload(id)
        installed.removeAll { $0.id == id }
        save()
    }

    func openOptions(_ id: String) {
        guard let url = loaded.first(where: { $0.id == id })?.context.optionsPageURL else { return }
        _ = openTab(url, true)
    }

    /// Runs the extension's toolbar action for the active tab (may present its popup).
    func performAction(_ id: String) {
        guard let context = loaded.first(where: { $0.id == id })?.context else { return }
        context.performAction(for: focusedWindow()?.tabs.active)
    }

    // MARK: Loading

    private func load(_ record: InstalledExtension, context existing: WKWebExtensionContext? = nil) async {
        guard !loaded.contains(where: { $0.id == record.id }) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else {
            lastError = "An installed extension's files are missing; remove and add it again."
            return
        }
        if url.startAccessingSecurityScopedResource() { scopedURLs[record.id] = url }
        do {
            let context: WKWebExtensionContext
            if let existing { context = existing } else { context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: url)) }
            context.uniqueIdentifier = record.id
            #if DEBUG
            context.isInspectable = true
            #endif
            // Only what the user approved at install time.
            for name in record.grantedPermissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name)) }
            for pattern in record.grantedPatterns {
                if let match = try? WKWebExtension.MatchPattern(string: pattern) { context.setPermissionStatus(.grantedExplicitly, for: match) }
            }
            try controller.load(context)
            loaded.append(Loaded(id: record.id, context: context))
            for window in windows() { window.registerWithExtensions(controller) }
        } catch {
            lastError = "Couldn't load an extension: \(error.localizedDescription)"
        }
    }

    private func unload(_ id: String) {
        if let context = loaded.first(where: { $0.id == id })?.context { try? controller.unload(context) }
        loaded.removeAll { $0.id == id }
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(installed) else { return }
        Task.detached(priority: .utility) {
            do { try await file.write(data) } catch { Log.app.error("Saving installed extensions failed") }
        }
    }

    private func confirmInstall(_ webExtension: WKWebExtension, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(webExtension.displayName ?? "this extension")”?"
        var lines: [String] = []
        if let description = webExtension.displayDescription { lines.append(description) }
        let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        let hosts = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        lines.append("It will be able to:")
        lines += permissions.map { "• \(Self.describe($0))" }
        if !hosts.isEmpty {
            lines.append(hosts.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") }
                         ? "• Read and change all your data on all websites"
                         : "• Read and change your data on: \(hosts.prefix(6).joined(separator: ", "))\(hosts.count > 6 ? "…" : "")")
        }
        lines.append("\nExtensions run in regular windows only, never in private windows.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.icon = webExtension.icon(for: CGSize(width: 64, height: 64))
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func describe(_ permission: String) -> String {
        switch permission {
        case "tabs": return "Read your open tabs' titles and addresses"
        case "storage", "unlimitedStorage": return "Store its own data"
        case "activeTab": return "Access the current page when you use it"
        case "scripting": return "Run scripts on pages it can access"
        case "cookies": return "Read and change cookies"
        case "webNavigation": return "See which pages you visit"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": return "Block or modify network requests"
        case "contextMenus", "menus": return "Add items to context menus"
        case "alarms": return "Run tasks on a schedule"
        case "notifications": return "Show notifications"
        case "clipboardWrite": return "Write to the clipboard"
        default: return permission
        }
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

    /// Runtime permission requests are asked, never granted silently.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let names = permissions.map { Self.describe($0.rawValue) }.sorted()
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
        guard let webView = action.popupWebView, let window = focusedWindow() else { return }
        window.presentExtensionPopup(webView)
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
