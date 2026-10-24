import AppKit
import Foundation

/// Folders outside the sandbox the user has granted for importing (`~/Library/Application Support`,
/// `~/Library/Safari`). Each grant is kept as a read-only, app-scoped security-scoped bookmark in a
/// sealed file, so later imports don't ask again; access is started only while an import or scan runs.
@MainActor
final class MigrationAccess {
    private let file: SealedFile?
    private var bookmarks: [MigrationRoot: Data] = [:]

    init(directory: URL?, keys: KeyStore = KeychainKeyStore()) {
        file = directory.map {
            SealedFile(url: $0.appendingPathComponent("migration-access.sealed"), keyName: "migration", purpose: "dev.arcclone.migration-access.v1", keys: keys)
        }
    }

    func load() async {
        guard let data = try? await file?.read(), let stored = try? JSONDecoder().decode([MigrationRoot: Data].self, from: data) else { return }
        bookmarks = stored
    }

    func isGranted(_ root: MigrationRoot) -> Bool { bookmarks[root] != nil }

    /// The user's real home folder (in the sandbox, `NSHomeDirectory()` is the app's container).
    static var realHome: URL {
        if let entry = getpwuid(getuid()) { return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true) }
        return URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }

    /// Asks the user to choose the folder, starting there, and remembers the grant.
    func grant(_ root: MigrationRoot) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.realHome.appendingPathComponent(root.relativeToHome, isDirectory: true)
        panel.message = "Click Grant Access to let ArcClone read your other browsers' bookmarks and history in \(root.displayPath). Nothing is changed there."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        bookmarks[root] = data
        await save()
        return true
    }

    /// Runs `work` with every granted folder accessible, then gives the access back.
    func withAccess<T>(_ work: ([MigrationRoot: URL]) async throws -> T) async rethrows -> T {
        var urls: [MigrationRoot: URL] = [:]
        var started: [URL] = []
        var refreshed = false
        for (root, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { started.append(url) }
            urls[root] = url
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[root] = fresh
                refreshed = true
            }
        }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        if refreshed { await save() }
        return try await work(urls)
    }

    private func save() async {
        guard let file, let data = try? JSONEncoder().encode(bookmarks) else { return }
        do { try await file.write(data) } catch { Log.app.error("Saving import folder access failed") }
    }
}
