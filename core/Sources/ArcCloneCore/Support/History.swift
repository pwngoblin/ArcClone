import Foundation
import Observation

/// Browsing history: every page visited in a regular (non-private) window. Encrypted at rest with
/// the same scheme as the session (`SealedFile`), pruned by age and size, never written for
/// private windows.
@MainActor @Observable
public final class History {
    public struct Visit: Codable, Identifiable, Equatable, Sendable {
        public var id: UUID
        public var url: URL
        public var title: String
        public var visitedAt: Date
    }

    public static let defaultRetentionDays = 90
    static let maxEntries = 20_000
    /// Revisiting the same page within this window updates one entry instead of adding another.
    static let coalesceInterval: TimeInterval = 30 * 60

    /// Most recent first.
    public private(set) var visits: [Visit] = [] { didSet { searchText = nil } }
    /// Lowercased title + address per visit, built on the first search after a change, so typing in
    /// the command bar doesn't lowercase the whole history on every keystroke.
    @ObservationIgnored private var searchText: [NSString]?
    public private(set) var isLoaded = false

    @ObservationIgnored private let file: SealedFile?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = Date.init

    /// `directory: nil` keeps history in memory only (tests).
    public init(directory: URL?, keys: KeyStore = KeychainKeyStore()) {
        file = directory.map {
            SealedFile(url: $0.appendingPathComponent("history.sealed"), keyName: "history", purpose: "dev.arcclone.history.v1", keys: keys)
        }
    }

    public var retentionDays: Int {
        let stored = UserDefaults.standard.object(forKey: Preferences.Key.historyRetentionDays) as? Int
        return stored ?? Self.defaultRetentionDays
    }

    public func load() async {
        defer { isLoaded = true }
        guard let file else { return }
        do {
            if let data = try await file.read() {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                visits = try decoder.decode([Visit].self, from: data)
                prune()
            }
        } catch {
            Log.app.error("History could not be decrypted; starting empty: \(String(describing: error), privacy: .public)")
            file.delete()
        }
    }

    // MARK: Recording

    public func record(url: URL, title: String?) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = now()
        if let index = visits.firstIndex(where: { $0.url == url }), time.timeIntervalSince(visits[index].visitedAt) < Self.coalesceInterval {
            var visit = visits.remove(at: index)
            visit.visitedAt = time
            if !title.isEmpty { visit.title = title }
            visits.insert(visit, at: 0)
        } else {
            visits.insert(Visit(id: UUID(), url: url, title: title, visitedAt: time), at: 0)
        }
        prune()
        scheduleSave()
    }

    /// Adds visits imported from another browser: one entry per page at its latest visit, merged
    /// with what's here (the newer visit wins). Retention and the size limit then apply as usual.
    /// Returns how many pages were added or updated.
    @discardableResult
    public func importVisits(_ imported: [(url: URL, title: String, visitedAt: Date)]) -> Int {
        var index = Dictionary(visits.enumerated().map { ($0.element.url, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var changed = 0
        for entry in imported where entry.url.scheme == "https" || entry.url.scheme == "http" {
            let title = String(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
            if let at = index[entry.url] {
                guard entry.visitedAt > visits[at].visitedAt else { continue }
                visits[at].visitedAt = entry.visitedAt
                if !title.isEmpty { visits[at].title = title }
            } else {
                index[entry.url] = visits.count
                visits.append(Visit(id: UUID(), url: entry.url, title: title, visitedAt: entry.visitedAt))
            }
            changed += 1
        }
        visits.sort { $0.visitedAt > $1.visitedAt }
        prune()
        scheduleSave()
        return changed
    }

    // MARK: Queries

    /// Newest visit per page whose title or URL contains `query`.
    public func search(_ query: String, limit: Int = 50) -> [Visit] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return unique(limit) { _ in true } }
        // Already lowercased, so a literal (byte-wise) search is enough, and several times faster.
        if searchText == nil { searchText = visits.map { ($0.title + "\n" + $0.url.absoluteString).lowercased() as NSString } }
        let text = searchText ?? []
        var seen = Set<URL>()
        var out: [Visit] = []
        for (index, visit) in visits.enumerated() where out.count < limit
            && text[index].range(of: needle, options: .literal).location != NSNotFound && seen.insert(visit.url).inserted {
            out.append(visit)
        }
        return out
    }

    public func recent(_ limit: Int) -> [Visit] { unique(limit) { _ in true } }

    /// One visit per URL, newest first. (An eager loop: a lazy filter may evaluate its predicate
    /// more than once per element, which breaks the `seen` bookkeeping.)
    private func unique(_ limit: Int, where matches: (Visit) -> Bool) -> [Visit] {
        var seen = Set<URL>()
        var out: [Visit] = []
        for visit in visits where out.count < limit && matches(visit) && seen.insert(visit.url).inserted {
            out.append(visit)
        }
        return out
    }

    // MARK: Removal

    public func remove(_ ids: Set<UUID>) {
        visits.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// Removes visits newer than `date` (Clear History: last hour, today, …); nil clears everything.
    public func clear(since date: Date? = nil) {
        if let date { visits.removeAll { $0.visitedAt >= date } } else { visits.removeAll() }
        scheduleSave()
    }

    // MARK: Persistence

    private func prune() {
        if retentionDays > 0 {
            let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
            visits.removeAll { $0.visitedAt < cutoff }
        }
        if visits.count > Self.maxEntries { visits.removeLast(visits.count - Self.maxEntries) }
    }

    /// Debounced; encryption and the write run off the main actor.
    private func scheduleSave() {
        guard let file else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // Batched: re-encrypting the whole history on every page view would waste CPU.
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            await self.write(to: file)
        }
    }

    /// Writes immediately (quit, Clear Browsing Data).
    public func flush() async {
        saveTask?.cancel()
        guard let file else { return }
        await write(to: file)
    }

    private func write(to file: SealedFile) async {
        let snapshot = visits
        await Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                if snapshot.isEmpty { file.delete() } else { try await file.write(encoder.encode(snapshot)) }
            } catch {
                Log.app.error("History save failed: \(String(describing: error), privacy: .public)")
            }
        }.value
    }
}
