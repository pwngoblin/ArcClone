import Foundation

/// Text typed into long fields (comments, posts, messages: textareas and rich editors), kept so
/// it can be put back if the page crashes, is closed or reloads before it's sent. Only those
/// fields: never passwords, card or one-time-code fields, `autocomplete=off` fields, or private
/// windows (`injections/modules/form-recovery.js` decides on the page; the routes check again).
///
/// Encrypted at rest like history (`SealedFile`), forgotten after 24 hours, capped in count and
/// size, removed when the field is sent or emptied, and by Clear Browsing Data.
@MainActor
public final class FormDrafts {
    public struct Draft: Codable, Equatable, Sendable {
        /// The page: origin and path, never the query or fragment (they can hold tokens).
        public var page: String
        /// Which field on the page (`form-recovery.js`).
        public var field: String
        public var text: String
        public var savedAt: Date
    }

    nonisolated static let lifetime: TimeInterval = 24 * 60 * 60
    nonisolated static let minCharacters = 20
    nonisolated static let maxCharacters = 40_000
    nonisolated static let maxFieldKey = 200
    nonisolated static let maxDrafts = 200

    /// Most recent first.
    public private(set) var drafts: [Draft] = []
    private let file: SealedFile?
    private var saveTask: Task<Void, Never>?
    var now: () -> Date = Date.init

    /// `directory: nil` keeps drafts in memory only (tests, self-test).
    public init(directory: URL?, keys: KeyStore = KeychainKeyStore()) {
        file = directory.map {
            SealedFile(url: $0.appendingPathComponent("form-drafts.sealed"), keyName: "formdrafts", purpose: "dev.arcclone.formdrafts.v1", keys: keys)
        }
    }

    /// The key drafts are stored under: scheme, host, port and path of an http(s) page.
    nonisolated static func pageKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme)://\(host)\(port)\(path)"
    }

    public func load() async {
        guard let file else { return }
        do {
            if let data = try await file.read() { drafts = try JSONDecoder().decode([Draft].self, from: data) }
        } catch {
            // Unreadable or tampered: start empty rather than trust it.
            Log.app.error("Form drafts failed authentication; ignoring them")
            drafts = []
        }
        if pruneExpired() { scheduleSave() }
    }

    /// Text typed into `field` on `page`. Shorter than `minCharacters` counts as nothing typed.
    func save(page url: URL, field: String, text: String) {
        guard let page = Self.pageKey(url), !field.isEmpty, field.count <= Self.maxFieldKey else { return }
        let text = String(text.prefix(Self.maxCharacters))
        drafts.removeAll { $0.page == page && $0.field == field }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minCharacters {
            drafts.insert(Draft(page: page, field: field, text: text, savedAt: now()), at: 0)
            if drafts.count > Self.maxDrafts { drafts.removeLast(drafts.count - Self.maxDrafts) }
        }
        scheduleSave()
    }

    /// The field was sent or emptied.
    func clear(page url: URL, field: String) {
        guard let page = Self.pageKey(url) else { return }
        let before = drafts.count
        drafts.removeAll { $0.page == page && $0.field == field }
        if drafts.count != before { scheduleSave() }
    }

    /// Unexpired drafts for `url`'s page, most recent first.
    func drafts(for url: URL) -> [Draft] {
        if pruneExpired() { scheduleSave() }
        guard let page = Self.pageKey(url) else { return [] }
        return drafts.filter { $0.page == page }
    }

    func clearPage(_ url: URL) {
        guard let page = Self.pageKey(url) else { return }
        drafts.removeAll { $0.page == page }
        scheduleSave()
    }

    public func removeAll() {
        drafts.removeAll()
        saveTask?.cancel()
        Task { await flush() }
    }

    /// Writes now (quit).
    public func flush() async {
        saveTask?.cancel()
        guard let file else { return }
        do {
            if drafts.isEmpty { file.delete() } else { try await file.write(JSONEncoder().encode(drafts)) }
        } catch {
            Log.app.error("Saving form drafts failed")
        }
    }

    @discardableResult
    private func pruneExpired() -> Bool {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        let before = drafts.count
        drafts.removeAll { $0.savedAt < cutoff }
        return drafts.count != before
    }

    /// Debounced: typing produces a snapshot every second or so; the file is written at most every 3 s.
    private func scheduleSave() {
        guard file != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await self.flush()
        }
    }
}
