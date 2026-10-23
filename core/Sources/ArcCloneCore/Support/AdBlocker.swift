import CryptoKit
import Foundation
import Observation
import WebKit

/// Blocks ads and trackers with WebKit content-rule lists: WebKit drops matching requests and
/// hides matching elements itself, before anything loads. A built-in list is always available;
/// EasyList + EasyPrivacy can be downloaded and converted (Settings → Privacy).
@MainActor @Observable
public final class AdBlocker {
    static let builtinID = "arcclone.builtin.v1"
    static let easyListID = "arcclone.easylist"
    static let sources = [URL(string: "https://easylist.to/easylist/easylist.txt")!,
                          URL(string: "https://easylist.to/easylist/easyprivacy.txt")!]
    static let refreshInterval: TimeInterval = 7 * 86_400

    public private(set) var status = "Preparing…"
    public private(set) var isUpdating = false
    @ObservationIgnored private var lists: [WKContentRuleList] = []
    @ObservationIgnored private var applied: [ObjectIdentifier: [String]] = [:]
    @ObservationIgnored private let store: WKContentRuleListStore?

    public init(store: WKContentRuleListStore? = .default()) {
        self.store = store
    }

    public var isEnabled: Bool { Preferences.flag(Preferences.Key.adBlock, default: true) }
    public var usesEasyList: Bool { Preferences.flag(Preferences.Key.easyList, default: false) }

    var lastUpdated: Date? { UserDefaults.standard.object(forKey: Preferences.Key.easyListUpdated) as? Date }

    /// Loads compiled lists (compiling the built-in one the first time) and refreshes EasyList when stale.
    public func prepare() async {
        guard let store else { return }
        var ready: [WKContentRuleList] = []
        do {
            ready.append(try await compiledOrCompile(Self.builtinID, rules: BuiltinBlocklist.rules, in: store))
        } catch {
            Log.web.error("Built-in blocklist failed to compile: \(error.localizedDescription, privacy: .public)")
        }
        if usesEasyList, let easy = try? await store.contentRuleList(forIdentifier: Self.easyListID) { ready.append(easy) }
        lists = ready
        applied.removeAll()
        updateStatus()
        if usesEasyList, (lastUpdated.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true) {
            await updateFilterLists()
        }
    }

    /// Downloads EasyList + EasyPrivacy over HTTPS, converts and compiles them.
    public func updateFilterLists() async {
        guard let store, !isUpdating else { return }
        isUpdating = true
        status = "Downloading EasyList and EasyPrivacy…"
        defer { isUpdating = false }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            var text = ""
            for source in Self.sources {
                let (data, response) = try await session.data(from: source)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 15_000_000,
                      let body = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
                text += body + "\n"
            }
            status = "Converting filter lists…"
            // Converted and encoded off the main actor; only the JSON string comes back.
            let (json, count) = try await Task.detached(priority: .utility) { () throws -> (String, Int) in
                let rules = FilterListConverter.convert(text)
                return (String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self), rules.count)
            }.value
            guard let compiled = try await store.compileContentRuleList(forIdentifier: Self.easyListID, encodedContentRuleList: json) else {
                throw URLError(.cannotParseResponse)
            }
            UserDefaults.standard.set(Date(), forKey: Preferences.Key.easyListUpdated)
            lists = lists.filter { $0.identifier != Self.easyListID } + [compiled]
            applied.removeAll()
            updateStatus(count: count)
        } catch {
            status = "Couldn't update filter lists: \(error.localizedDescription)"
        }
    }

    /// Settings toggled: reload what's compiled.
    public func settingsChanged() {
        Task { await prepare() }
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

    private func updateStatus(count: Int? = nil) {
        if !isEnabled { status = "Off"; return }
        let easy = lists.contains { $0.identifier == Self.easyListID }
        var text = easy ? "Built-in list + EasyList & EasyPrivacy" : "Built-in list (\(BuiltinBlocklist.domains.count) networks)"
        if let count { text += " · \(count.formatted()) rules" }
        if easy, let date = lastUpdated { text += " · updated \(date.formatted(.relative(presentation: .named)))" }
        status = text
    }
}
