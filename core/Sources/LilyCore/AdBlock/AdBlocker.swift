import CryptoKit
import Foundation
import Observation
import WebKit

/// Blocks ads and trackers with WebKit content-rule lists: WebKit drops matching requests and
/// hides matching elements itself, before anything loads. A built-in list is always available;
/// filter lists (EasyList, uBlock filters, …) can be turned on in Settings → Privacy, and are
/// downloaded, converted (`FilterListConverter`) and compiled into WebKit lists. The few hiding
/// rules WebKit can't express run in the page (`cosmetic-filter.js`), fetched per site.
@MainActor @Observable
public final class AdBlocker {
    static let builtinID = "lily.builtin.v1"
    static let chunkPrefix = "lily.filters."
    static let legacyEasyListID = "lily.easylist"
    static let refreshInterval: TimeInterval = 7 * 86_400
    static let maxListBytes = 15_000_000

    public private(set) var status = "Preparing…"
    public private(set) var isUpdating = false
    public private(set) var enabledLists: Set<String> = FilterLists.enabled
    @ObservationIgnored private var builtin: WKContentRuleList?
    @ObservationIgnored private var filterLists: [WKContentRuleList] = []
    @ObservationIgnored private var procedural: [String: [ProceduralFilter]] = [:]
    @ObservationIgnored private var ruleCount: Int?
    @ObservationIgnored private var applied: [ObjectIdentifier: [String]] = [:]
    @ObservationIgnored private var rebuildAgain = false
    @ObservationIgnored private let store: WKContentRuleListStore?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let keys: KeyStore

    /// `directory`: where downloaded lists and in-page filters are cached (sealed); nil keeps them in memory only.
    public init(store: WKContentRuleListStore? = .default(), directory: URL? = nil, keys: KeyStore = KeychainKeyStore()) {
        self.store = store
        self.directory = directory.map { $0.appendingPathComponent("FilterLists", isDirectory: true) }
        self.keys = keys
    }

    public var isEnabled: Bool { Preferences.flag(Preferences.Key.adBlock, default: true) }

    var lastUpdated: Date? { UserDefaults.standard.object(forKey: Preferences.Key.filterListsUpdated) as? Date }

    private var lists: [WKContentRuleList] { (builtin.map { [$0] } ?? []) + filterLists }

    /// Loads compiled lists (compiling the built-in one the first time). Rebuilding or refreshing
    /// filter lists happens in the background so it never delays opening windows.
    public func prepare() async {
        guard let store else { return }
        do {
            builtin = try await compiledOrCompile(Self.builtinID, rules: BuiltinBlocklist.rules, in: store)
        } catch {
            Log.web.error("Built-in blocklist failed to compile: \(error.localizedDescription, privacy: .public)")
        }
        try? await store.removeContentRuleList(forIdentifier: Self.legacyEasyListID)

        let compiledFrom = UserDefaults.standard.stringArray(forKey: Preferences.Key.filterListsCompiledFrom) ?? []
        if Set(compiledFrom) == enabledLists, !enabledLists.isEmpty {
            var loaded: [WKContentRuleList] = []
            for id in UserDefaults.standard.stringArray(forKey: Preferences.Key.filterListsCompiled) ?? [] {
                if let list = try? await store.contentRuleList(forIdentifier: id) { loaded.append(list) }
            }
            filterLists = loaded
            procedural = await loadProcedural()
        }
        applied.removeAll()
        updateStatus()

        let changed = Set(compiledFrom) != enabledLists
        let stale = lastUpdated.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        if changed || (!enabledLists.isEmpty && stale) {
            Task { await rebuild(download: stale) }
        }
    }

    public func isListEnabled(_ id: String) -> Bool { enabledLists.contains(id) }

    /// Turns a list on or off and recompiles (downloading only lists that aren't cached yet).
    public func setList(_ id: String, enabled: Bool) {
        guard FilterLists.list(id) != nil else { return }
        if enabled { enabledLists.insert(id) } else { enabledLists.remove(id) }
        FilterLists.enabled = enabledLists
        Task { await rebuild(download: false) }
    }

    /// Downloads every turned-on list again and recompiles.
    public func updateFilterLists() async {
        await rebuild(download: true)
    }

    /// Settings toggled: reload what's compiled.
    public func settingsChanged() {
        applied.removeAll()
        updateStatus()
    }

    /// Attaches (or detaches) the lists for the page about to load in this tab.
    func configure(_ controller: WKUserContentController, adsAllowed: Bool) {
        let wanted = isEnabled && !adsAllowed ? lists : []
        let ids = wanted.compactMap(\.identifier)
        let key = ObjectIdentifier(controller)
        guard applied[key] != ids else { return }
        controller.removeAllContentRuleLists()
        wanted.forEach(controller.add)
        applied[key] = ids
    }

    func forget(_ controller: WKUserContentController) {
        applied[ObjectIdentifier(controller)] = nil
    }

    /// In-page hiding filters for a site and its parent domains (`a.b.example.com` → … → `example.com`).
    func proceduralFilters(for host: String) -> [ProceduralFilter] {
        guard isEnabled, !procedural.isEmpty else { return [] }
        var found: [ProceduralFilter] = []
        var name = Substring(host.lowercased())
        while true {
            found += procedural[String(name)] ?? []
            guard let dot = name.firstIndex(of: ".") else { break }
            name = name[name.index(after: dot)...]
        }
        return Array(found.prefix(FilterListConverter.maxProceduralPerDomain * 2))
    }

    /// Self-test: in-page filters without downloading lists.
    func useProceduralFilters(_ filters: [String: [ProceduralFilter]]) {
        procedural = filters
    }

    // MARK: Building

    private func rebuild(download: Bool) async {
        guard let store else { return }
        guard !isUpdating else { rebuildAgain = true; return }
        isUpdating = true
        defer { isUpdating = false }
        repeat {
            rebuildAgain = false
            let wanted = FilterLists.all.filter { enabledLists.contains($0.id) }
            if wanted.isEmpty {
                await install([], procedural: [:], ruleCount: nil, from: [], in: store)
                continue
            }
            var texts: [String] = []
            var failures: [String] = []
            status = download ? "Downloading filter lists…" : "Preparing filter lists…"
            for list in wanted {
                if !download, let cached = await cached(list) { texts.append(cached); continue }
                do {
                    let text = try await fetch(list)
                    texts.append(text)
                    await cache(text, for: list)
                } catch {
                    Log.web.error("Filter list \(list.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    if let cached = await cached(list) { texts.append(cached) } else { failures.append(list.name) }
                }
            }
            status = "Converting filter lists…"
            do {
                let combined = texts.joined(separator: "\n")
                // Converted and encoded off the main actor; only JSON strings come back.
                let compiled = try await Task.detached(priority: .utility) { try FilterListConverter.compile(combined) }.value
                status = "Compiling \(compiled.ruleCount.formatted()) rules…"
                await install(compiled.chunks, procedural: compiled.procedural, ruleCount: compiled.ruleCount,
                              from: wanted.map(\.id), in: store)
                if download, failures.count < wanted.count { UserDefaults.standard.set(Date(), forKey: Preferences.Key.filterListsUpdated) }
                if !failures.isEmpty { status = "Couldn't download \(failures.joined(separator: ", ")). " + status }
            } catch {
                status = "Couldn't compile filter lists: \(Sanitize.errorMessage(error))"
            }
        } while rebuildAgain
    }

    /// Compiles the chunks into WebKit lists, then swaps them in and removes leftovers.
    private func install(_ chunks: [String], procedural newProcedural: [String: [ProceduralFilter]], ruleCount count: Int?,
                         from ids: [String], in store: WKContentRuleListStore) async {
        var compiled: [WKContentRuleList] = []
        do {
            for (index, json) in chunks.enumerated() {
                guard let list = try await store.compileContentRuleList(forIdentifier: Self.chunkPrefix + String(index), encodedContentRuleList: json) else {
                    throw URLError(.cannotParseResponse)
                }
                compiled.append(list)
            }
        } catch {
            status = "Couldn't compile filter lists: \(Sanitize.errorMessage(error))"
            return
        }
        let identifiers = compiled.compactMap(\.identifier)
        for stale in (UserDefaults.standard.stringArray(forKey: Preferences.Key.filterListsCompiled) ?? []) where !identifiers.contains(stale) {
            try? await store.removeContentRuleList(forIdentifier: stale)
        }
        UserDefaults.standard.set(identifiers, forKey: Preferences.Key.filterListsCompiled)
        UserDefaults.standard.set(ids, forKey: Preferences.Key.filterListsCompiledFrom)
        filterLists = compiled
        procedural = newProcedural
        ruleCount = count
        await saveProcedural(newProcedural)
        applied.removeAll()
        updateStatus()
    }

    private func fetch(_ list: FilterList) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var text = ""
        for source in list.sources {
            let (data, response) = try await session.data(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < Self.maxListBytes,
                  let body = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
            text += body + "\n"
        }
        return text
    }

    // MARK: Cache (sealed files: lists can't be swapped by another process to unblock trackers)

    private func file(_ name: String) -> SealedFile? {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SealedFile(url: directory.appendingPathComponent(name + ".sealed"), keyName: "filterlists",
                          purpose: "dev.lily.filterlists.\(name).v1", keys: keys)
    }

    private func cached(_ list: FilterList) async -> String? {
        guard let data = try? await file(list.id)?.read() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func cache(_ text: String, for list: FilterList) async {
        try? await file(list.id)?.write(Data(text.utf8))
    }

    private func loadProcedural() async -> [String: [ProceduralFilter]] {
        guard let data = try? await file("procedural")?.read() else { return [:] }
        return (try? JSONDecoder().decode([String: [ProceduralFilter]].self, from: data)) ?? [:]
    }

    private func saveProcedural(_ filters: [String: [ProceduralFilter]]) async {
        guard let file = file("procedural") else { return }
        if filters.isEmpty { file.delete(); return }
        if let data = try? JSONEncoder().encode(filters) { try? await file.write(data) }
    }

    private func compiledOrCompile(_ id: String, rules: [[String: Any]], in store: WKContentRuleListStore) async throws -> WKContentRuleList {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
        // Recompile when the rules change between versions.
        let versionKey = "ContentRuleListHash.\(id)"
        let hash = SHA256.hash(data: Data(json.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if UserDefaults.standard.string(forKey: versionKey) == hash, let cached = try? await store.contentRuleList(forIdentifier: id) {
            return cached
        }
        guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
            throw URLError(.cannotParseResponse)
        }
        UserDefaults.standard.set(hash, forKey: versionKey)
        return list
    }

    private func updateStatus() {
        if !isEnabled { status = "Off"; return }
        guard !filterLists.isEmpty else {
            status = "Built-in list (\(BuiltinBlocklist.domains.count) networks)"
            return
        }
        let names = FilterLists.all.filter { enabledLists.contains($0.id) }.map(\.name)
        var text = "Built-in list + " + names.formatted(.list(type: .and))
        if let ruleCount { text += " · \(ruleCount.formatted()) rules" }
        if let date = lastUpdated { text += " · updated \(date.formatted(.relative(presentation: .named)))" }
        status = text
    }
}
