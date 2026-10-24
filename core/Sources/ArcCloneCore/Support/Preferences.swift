import Foundation

/// User settings stored in UserDefaults. Keys are shared with the SwiftUI settings window
/// (`@AppStorage`) and `AssistantConfiguration`, so changing one here changes both.
public enum Preferences {
    public enum Key {
        public static let searchEngine = "SearchEngine"
        public static let homepage = "Homepage"
        public static let ollamaHost = "OllamaHost"
        public static let agentModel = "AgentModel"
        /// Comma-separated base64 SHA-256 SPKI pins for a remote (HTTPS) Ollama.
        public static let ollamaPins = "OllamaPinnedKeys"
        /// Days of browsing history to keep; 0 keeps everything.
        public static let historyRetentionDays = "HistoryRetentionDays"
        public static let defaultZoom = "DefaultPageZoom"
        public static let defaultDarkMode = "DefaultWebsiteAppearance"
        public static let httpsFirst = "HTTPSFirst"
        public static let restoreSession = "RestoreTabsOnLaunch"
        public static let newTabsNextToCurrent = "OpenNewTabsNextToCurrent"
        public static let clearHistoryOnQuit = "ClearHistoryOnQuit"
        public static let clearWebsiteDataOnQuit = "ClearWebsiteDataOnQuit"
        public static let adBlock = "BlockAdsAndTrackers"
        public static let haptics = "HapticFeedback"
        /// Minutes before an unused background tab sleeps; 0 means never.
        public static let sleepTabsAfter = "SleepTabsAfterMinutes"
        public static let easyList = "UseEasyList"
        public static let easyListUpdated = "EasyListUpdated"
    }

    public enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
        case google, duckDuckGo, bing, kagi, ecosia

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .google: return "Google"
            case .duckDuckGo: return "DuckDuckGo"
            case .bing: return "Bing"
            case .kagi: return "Kagi"
            case .ecosia: return "Ecosia"
            }
        }

        public var template: String {
            switch self {
            case .google: return "https://www.google.com/search?q=%s"
            case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
            case .bing: return "https://www.bing.com/search?q=%s"
            case .kagi: return "https://kagi.com/search?q=%s"
            case .ecosia: return "https://www.ecosia.org/search?q=%s"
            }
        }
    }

    public static let defaultHomepage = "https://www.youtube.com"

    /// Bool preferences that default to on when never set.
    static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    public static var httpsFirstEnabled: Bool { flag(Key.httpsFirst, default: true) }
    public static var restoresSession: Bool { flag(Key.restoreSession, default: true) }
    public static var opensTabsNextToCurrent: Bool { flag(Key.newTabsNextToCurrent, default: true) }

    public static var searchEngine: SearchEngine {
        UserDefaults.standard.string(forKey: Key.searchEngine).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    /// Address-bar resolver using the user's search engine.
    public static var urlResolver: URLResolver { URLResolver(searchTemplate: searchEngine.template) }

    public static var homepage: URL? {
        let raw = UserDefaults.standard.string(forKey: Key.homepage) ?? defaultHomepage
        return raw.isEmpty ? nil : urlResolver.resolve(raw)
    }
}

public enum AppInfo {
    /// `CFBundleShortVersionString` of the packaged app, or "dev" for `swift run` builds.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Running from a .app bundle. Packaged builds ignore developer overrides (environment
    /// variables, PATH, repository lookup) so nothing outside the signed bundle can change
    /// which scripts the app injects or which executables it runs.
    public static var isPackaged: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public static let helpURL = URL(string: "https://github.com/pwngoblin/ArcClone#readme")!
}
