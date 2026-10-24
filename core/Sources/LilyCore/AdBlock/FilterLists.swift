import Foundation

/// A downloadable filter list (several files for lists published in parts).
public struct FilterList: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let summary: String
    let sources: [URL]
}

/// The lists offered in Settings → Privacy. All are fetched over HTTPS from their maintainers and
/// combined before conversion, so one list's exceptions can fix breakage caused by another.
public enum FilterLists {
    public static let all: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", summary: "Ads on most websites",
                   sources: [URL(string: "https://easylist.to/easylist/easylist.txt")!]),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", summary: "Tracking scripts, pixels and analytics",
                   sources: [URL(string: "https://easylist.to/easylist/easyprivacy.txt")!]),
        FilterList(id: "ublock", name: "uBlock filters", summary: "uBlock Origin's ad filters and its fixes for sites other lists break",
                   sources: [URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!,
                             URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!,
                             URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt")!]),
        FilterList(id: "ublock-privacy", name: "uBlock filters – Privacy", summary: "More trackers, from uBlock Origin",
                   sources: [URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!]),
        FilterList(id: "peter-lowe", name: "Peter Lowe's list", summary: "Ad and tracking servers",
                   sources: [URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!]),
        FilterList(id: "adguard-annoyances", name: "AdGuard Annoyances", summary: "Cookie notices, pop-ups, app banners and other annoyances",
                   sources: [URL(string: "https://filters.adtidy.org/extension/ublock/filters/14.txt")!]),
    ]

    static func list(_ id: String) -> FilterList? { all.first { $0.id == id } }

    /// Turned-on list ids. Before per-list settings, one switch covered EasyList + EasyPrivacy.
    static var enabled: Set<String> {
        get {
            if let ids = UserDefaults.standard.stringArray(forKey: Preferences.Key.filterLists) {
                return Set(ids).intersection(all.map(\.id))
            }
            return Preferences.flag(Preferences.Key.easyList, default: false) ? ["easylist", "easyprivacy"] : []
        }
        set { UserDefaults.standard.set(all.map(\.id).filter(newValue.contains), forKey: Preferences.Key.filterLists) }
    }
}
