import Foundation

/// `chrome.storage.local` for compatibility-mode extensions (macOS 14–15.3; on 15.4+ WebKit keeps
/// extension storage itself). One sealed file per extension, capped like Chrome's 10 MB quota.
@ExtensionActor
final class ExtensionStorage {
    static let quotaBytes = 10 * 1024 * 1024

    struct QuotaExceeded: LocalizedError {
        var errorDescription: String? { "The extension's storage is full (10 MB)." }
    }

    private let directory: URL?
    private let keys: KeyStore
    private var cache: [String: [String: JSONValue]] = [:]

    nonisolated init(directory: URL?, keys: KeyStore) {
        self.directory = directory.map { $0.appendingPathComponent("ExtensionStorage", isDirectory: true) }
        self.keys = keys
    }

    func get(_ extensionID: String, keys requested: [String]?) async -> [String: JSONValue] {
        let items = await load(extensionID)
        guard let requested else { return items }
        return items.filter { requested.contains($0.key) }
    }

    func set(_ extensionID: String, _ items: [String: JSONValue]) async throws {
        var stored = await load(extensionID)
        stored.merge(items) { _, new in new }
        guard JSONValue.object(stored).jsonData().count <= Self.quotaBytes else { throw QuotaExceeded() }
        await save(extensionID, stored)
    }

    func remove(_ extensionID: String, keys removed: [String]) async {
        var stored = await load(extensionID)
        removed.forEach { stored[$0] = nil }
        await save(extensionID, stored)
    }

    func clear(_ extensionID: String) async {
        await save(extensionID, [:])
    }

    private func file(_ extensionID: String) -> SealedFile? {
        guard let directory, ExtensionPackage.sanitized(extensionID) == extensionID, !extensionID.contains("/") else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return SealedFile(url: directory.appendingPathComponent(extensionID + ".sealed"), keyName: "extensions",
                          purpose: "dev.lily.extension-storage.v1", keys: keys)
    }

    private func load(_ extensionID: String) async -> [String: JSONValue] {
        if let cached = cache[extensionID] { return cached }
        let items = (try? await file(extensionID)?.read()).flatMap { $0 }.flatMap { try? JSONValue.parse($0) }?.object ?? [:]
        cache[extensionID] = items
        return items
    }

    private func save(_ extensionID: String, _ items: [String: JSONValue]) async {
        cache[extensionID] = items
        guard let file = file(extensionID) else { return }
        if items.isEmpty { file.delete(); return }
        do { try await file.write(JSONValue.object(items).jsonData()) } catch { Log.extensions.error("Saving extension storage failed") }
    }
}
