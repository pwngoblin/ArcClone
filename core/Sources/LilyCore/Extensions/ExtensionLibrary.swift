import AppKit
import Observation
import UniformTypeIdentifiers

/// One installed extension as remembered between launches.
struct InstalledExtension: Codable, Identifiable, Equatable {
    var id: String
    /// Older installs: a read-only bookmark to the user's folder or .zip. Pinned on next load.
    var bookmark: Data?
    /// The audited copy in the app container (a folder name under Extensions/) and its SHA-256.
    var pinnedFolder: String?
    var contentHash: String?
    var enabled: Bool
    var grantedPermissions: [String]
    var grantedPatterns: [String]
    /// The Chrome Web Store ID it was downloaded as, when it came from the store.
    var storeID: String? = nil
}

/// The installed extensions, on every macOS version: adding (audit, approval, pinning), the sealed
/// list, and integrity checks. A runtime turns `ready` entries into running extensions: WebKit's
/// extension controller on macOS 15.4+ (`ExtensionManager`), or content scripts only on older
/// systems (`ExtensionScriptInjector`). File work happens on `ExtensionActor`.
@MainActor @Observable
final class ExtensionLibrary {
    /// An enabled extension whose pinned copy passed its integrity check.
    struct Entry: Identifiable {
        let id: String
        let manifest: ExtensionManifest
        /// The manifest and content-script files only: compatibility mode injects those from
        /// memory; everything else (WebKit's runtime included) reads the pinned folder.
        let package: ExtensionPackage
        let folder: URL
        let icon: NSImage?
        var name: String { manifest.name }
        var version: String { manifest.version }
        var summary: String { manifest.description ?? "" }
    }

    static let storageKey = "InstalledWebExtensions"
    private(set) var installed: [InstalledExtension] = []
    private(set) var ready: [Entry] = []
    private(set) var lastError: String?
    /// What a Chrome Web Store install is doing ("Downloading…"), nil when none is running.
    private(set) var storeStatus: String?
    /// The runtime listens here to load and unload extensions.
    @ObservationIgnored var onReadyChange: (@MainActor () -> Void)?
    @ObservationIgnored let storage: ExtensionStorage
    /// The list decides what code runs in pages, so it's sealed (encrypted and authenticated with the
    /// Keychain key) rather than kept in UserDefaults, where another process could add an "extension".
    @ObservationIgnored private let file: SealedFile?
    @ObservationIgnored private let pinnedRoot: URL?
    /// `injections/extension-worker-compat.js`, added to each extension's background (`ExtensionCompat`).
    @ObservationIgnored private let workerShim: Data?
    /// Names, versions and icons of disabled extensions too, for Settings.
    @ObservationIgnored private var info: [String: (name: String, version: String, summary: String, icon: NSImage?)] = [:]

    init(directory: URL?, keys: KeyStore = KeychainKeyStore(), workerShim: Data? = nil) {
        pinnedRoot = directory?.appendingPathComponent("Extensions", isDirectory: true)
        self.workerShim = workerShim
        file = directory.map {
            SealedFile(url: $0.appendingPathComponent("extensions.sealed"), keyName: "extensions", purpose: "dev.lily.extensions.v1", keys: keys)
        }
        storage = ExtensionStorage(directory: directory, keys: keys)
    }

    func entry(_ id: String) -> Entry? { ready.first { $0.id == id } }

    func displayName(_ id: String) -> String { info[id]?.name ?? entry(id)?.name ?? "Extension" }
    func displayVersion(_ id: String) -> String { info[id]?.version ?? "" }
    func summary(_ id: String) -> String { info[id]?.summary ?? "" }
    func icon(_ id: String) -> NSImage? { info[id]?.icon }

    /// The first 12 hex digits of the pinned copy's SHA-256, for display.
    func pinnedHash(_ id: String) -> String? {
        installed.first { $0.id == id }?.contentHash.map { String($0.prefix(12)) }
    }

    /// Reads the sealed list (migrating the old UserDefaults copy once) and prepares every extension.
    func loadAll() async {
        do {
            if let data = try await file?.read() { installed = try JSONDecoder().decode([InstalledExtension].self, from: data) }
        } catch {
            // Tampered or unreadable: load nothing rather than trust it.
            Log.extensions.error("Installed extensions list failed authentication; ignoring it")
            lastError = "The list of installed extensions couldn't be verified, so no extensions were loaded. Add them again."
            installed = []
        }
        if let legacy = UserDefaults.standard.data(forKey: Self.storageKey) {
            if installed.isEmpty, let old = try? JSONDecoder().decode([InstalledExtension].self, from: legacy) { installed = old }
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            save()
        }
        for record in installed { await prepare(record) }
    }

    // MARK: Install / remove

    /// Picks an extension folder, .zip or Chrome Web Store .crx; audits it; shows the findings and
    /// what it asks for; and installs a pinned copy if approved.
    func install(presentingIn window: NSWindow?) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder] + [UTType(filenameExtension: "crx")].compactMap { $0 }
        panel.message = "Choose a web extension: an unpacked folder (with manifest.json), a .zip, or a .crx"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let shim = workerShim
        await install(storeID: nil) { try await ExtensionLoader.inspect(url, compat: shim) }
    }

    /// Adds an extension from a Chrome Web Store link or 32-letter ID: downloads its CRX3, verifies
    /// the signatures and that it's the extension asked for, then audits, asks and pins it as usual.
    func install(fromStore input: String) async {
        guard storeStatus == nil else { return }
        guard let id = ChromeWebStore.extensionID(from: input) else {
            lastError = "Paste a Chrome Web Store link (chromewebstore.google.com/detail/…) or a 32-letter extension ID."
            return
        }
        lastError = nil
        storeStatus = "Downloading…"
        defer { storeStatus = nil }
        await install(storeID: id) {
            let data = try await ChromeWebStore.download(id)
            self.storeStatus = "Checking signature and code…"
            return try await ExtensionLoader.inspect(crx: data, expectedID: id, compat: self.workerShim)
        }
    }

    private func install(storeID: String?, _ inspect: () async throws -> InspectedExtension) async {
        guard let pinnedRoot else { return }
        let folder = pinnedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let inspected = try await inspect()
            guard !inspected.audit.isBlocked else { showBlocked(inspected.audit); return }
            guard let manifest = inspected.manifest else { throw ExtensionPackage.Invalid(reason: "manifest.json isn't valid.") }
            let hash = inspected.package.contentHash
            guard !installed.contains(where: { $0.contentHash == hash }) else {
                lastError = "“\(manifest.name)” \(manifest.version) is already installed."
                return
            }
            // A newer copy of a store extension replaces the old one and keeps its data.
            let previous = storeID.flatMap { id in installed.first { $0.storeID == id } }
            guard confirmInstall(manifest, package: inspected.package, audit: inspected.audit, hash: hash,
                                 replacing: previous.map { displayVersion($0.id) }) else { return }
            try await ExtensionLoader.pin(inspected.package, to: folder)
            let record = InstalledExtension(id: previous?.id ?? UUID().uuidString, bookmark: nil, pinnedFolder: folder.lastPathComponent,
                                            contentHash: hash, enabled: true, grantedPermissions: manifest.permissions,
                                            grantedPatterns: Self.requestedPatterns(manifest), storeID: storeID)
            if let previous, let index = installed.firstIndex(where: { $0.id == previous.id }) {
                ready.removeAll { $0.id == previous.id }
                onReadyChange?()
                if let old = previous.pinnedFolder, let pinnedRoot = self.pinnedRoot {
                    try? FileManager.default.removeItem(at: pinnedRoot.appendingPathComponent(old, isDirectory: true))
                }
                installed[index] = record
            } else {
                installed.append(record)
            }
            save()
            lastError = nil
            await prepare(record)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            lastError = "Couldn't install: \(Sanitize.errorMessage(error))"
        }
    }

    static func requestedPatterns(_ manifest: ExtensionManifest) -> [String] {
        Array(Set(manifest.allHostPatterns + manifest.contentScripts.flatMap(\.matches))).sorted()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        save()
        if enabled {
            Task { await prepare(installed[index]) }
        } else {
            ready.removeAll { $0.id == id }
            onReadyChange?()
        }
    }

    func remove(_ id: String) {
        ready.removeAll { $0.id == id }
        if let folder = installed.first(where: { $0.id == id })?.pinnedFolder, let pinnedRoot {
            try? FileManager.default.removeItem(at: pinnedRoot.appendingPathComponent(folder, isDirectory: true))
        }
        installed.removeAll { $0.id == id }
        info[id] = nil
        save()
        Task { await storage.clear(id) }
        onReadyChange?()
    }

    /// Tests: treat an already-verified entry as ready, without the install flow.
    func adoptForTesting(_ entry: Entry, record: InstalledExtension) {
        installed.append(record)
        ready.append(entry)
        onReadyChange?()
    }

    // MARK: Preparing

    /// Pins legacy installs, verifies the pinned copy against its hash, and (if enabled) makes it ready.
    private func prepare(_ record: InstalledExtension) async {
        guard let record = await pinIfNeeded(record), let folderName = record.pinnedFolder, let expected = record.contentHash,
              let folder = pinnedRoot?.appendingPathComponent(folderName, isDirectory: true) else { return }
        // The pinned copy must be exactly what was audited and approved.
        guard let package = await ExtensionLoader.verifiedPackage(at: folder, expectedHash: expected),
              let manifest = ExtensionManifest.parse(package) else {
            Log.extensions.error("Pinned extension \(record.id, privacy: .private) failed its integrity check")
            lastError = "An extension's files changed after it was added, so it wasn't loaded. Remove it and add it again."
            return
        }
        let icon = manifest.iconPath(for: 64).flatMap { package.files[$0] }.flatMap(NSImage.init(data:))
        info[record.id] = (manifest.name, manifest.version, manifest.description ?? "", icon)
        guard record.enabled, installed.contains(where: { $0.id == record.id && $0.enabled }), !ready.contains(where: { $0.id == record.id }) else { return }
        let scripts = Set(manifest.contentScripts.flatMap { ($0.js ?? []) + ($0.css ?? []) } + ["manifest.json"])
        let resident = (try? ExtensionPackage(files: package.files.filter { scripts.contains($0.key) })) ?? package
        ready.append(Entry(id: record.id, manifest: manifest, package: resident, folder: folder, icon: icon))
        onReadyChange?()
    }

    /// Older installs ran straight from the user's folder or .zip. On their next load they're copied
    /// into the container, audited and hashed once; from then on that copy is what runs.
    private func pinIfNeeded(_ record: InstalledExtension) async -> InstalledExtension? {
        if record.pinnedFolder != nil { return record }
        var stale = false
        guard let bookmark = record.bookmark, let pinnedRoot,
              let source = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else {
            lastError = "An installed extension's files are missing; remove and add it again."
            return nil
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let folder = pinnedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let inspected = try await ExtensionLoader.inspect(source, compat: workerShim)
            guard !inspected.audit.isBlocked else {
                lastError = "An extension can run code from outside itself, so it was turned off. Remove it."
                return nil
            }
            try await ExtensionLoader.pin(inspected.package, to: folder)
            var pinned = record
            pinned.bookmark = nil
            pinned.pinnedFolder = folder.lastPathComponent
            pinned.contentHash = inspected.package.contentHash
            if let index = installed.firstIndex(where: { $0.id == record.id }) { installed[index] = pinned }
            save()
            return pinned
        } catch {
            try? FileManager.default.removeItem(at: folder)
            lastError = "Couldn't load an extension: \(Sanitize.errorMessage(error))"
            return nil
        }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(installed) else { return }
        Task.detached(priority: .utility) {
            do { try await file.write(data) } catch { Log.extensions.error("Saving installed extensions failed") }
        }
    }

    // MARK: Dialogs

    private func showBlocked(_ audit: ExtensionAudit) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This extension can't be added"
        alert.informativeText = "It could run code that isn't part of the extension itself, so it can't be checked or pinned:\n\n"
            + audit.findings.filter { $0.severity == .blocked }.map { "• \($0.title) (\($0.detail))" }.joined(separator: "\n")
        alert.runModal()
    }

    private func confirmInstall(_ manifest: ExtensionManifest, package: ExtensionPackage, audit: ExtensionAudit, hash: String,
                                replacing oldVersion: String? = nil) -> Bool {
        let alert = NSAlert()
        switch oldVersion {
        case nil: alert.messageText = "Add “\(manifest.name)”?"
        case manifest.version?: alert.messageText = "Reinstall “\(manifest.name)” \(manifest.version)?"
        case let old?: alert.messageText = "Update “\(manifest.name)” from \(old) to \(manifest.version)?"
        }
        var lines: [String] = []
        if let description = manifest.description, !description.isEmpty { lines.append(description) }
        let hosts = Self.requestedPatterns(manifest)
        lines.append("It will be able to:")
        lines += manifest.permissions.sorted().map { "• \(Self.describe($0))" }
        if !hosts.isEmpty {
            lines.append(hosts.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") }
                         ? "• Read and change all your data on all websites"
                         : "• Read and change your data on: \(hosts.prefix(6).joined(separator: ", "))\(hosts.count > 6 ? "…" : "")")
        }
        let notable = audit.findings.filter { $0.severity >= .warning }
        if !notable.isEmpty {
            lines.append("\nReview found:")
            lines += notable.map { "⚠︎ \($0.title) (\($0.detail))" }
        }
        for info in audit.findings where info.severity == .info { lines.append("• \(info.title) (\(info.detail))") }
        if package.files[ExtensionCompat.shimPath] != nil {
            lines.append("\nLily adds stand-ins for Chrome features WebKit doesn't have (privacy settings and similar), so its background can start; they do nothing outside the extension. If it asks for notifications, Lily shows them through macOS.")
        }
        if #unavailable(macOS 15.4) {
            lines.append("\nOn this version of macOS only its page scripts run; popups and background features need macOS 15.4 or later.")
        }
        lines.append("\nThis exact copy is pinned (SHA-256 \(hash.prefix(12))…) and never updates on its own. Extensions run in regular windows only, never in private windows.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.icon = manifest.iconPath(for: 64).flatMap { package.files[$0] }.flatMap(NSImage.init(data:))
        alert.addButton(withTitle: oldVersion == nil ? "Add Extension" : oldVersion == manifest.version ? "Reinstall" : "Update")
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
        case "nativeMessaging": return "Talk to apps on your Mac (not supported in Lily)"
        default: return permission
        }
    }
}
