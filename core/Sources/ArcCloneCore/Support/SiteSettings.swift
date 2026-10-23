import Foundation
import Observation

/// Per-website preferences (zoom, dark mode, JavaScript, camera/microphone). Keyed by host;
/// encrypted at rest because the list reveals which sites you use. Values left nil follow the
/// defaults in Settings → Websites.
@MainActor @Observable
public final class SiteSettings {
    public enum DarkMode: String, Codable, CaseIterable, Sendable {
        /// Whatever the site and the system decide.
        case standard
        /// Ask the site for its own dark theme (`prefers-color-scheme: dark`).
        case dark
        /// Dark theme if the site has one, otherwise invert it (images and video stay natural).
        case forced
        /// Always light, even when macOS is in Dark Mode.
        case light

        var title: String {
            switch self {
            case .standard: return "Default"
            case .dark: return "Dark"
            case .forced: return "Force Dark"
            case .light: return "Light"
            }
        }
    }

    public enum Permission: String, Codable, CaseIterable, Sendable {
        case ask, allow, deny
        var title: String { rawValue.capitalized }
    }

    public struct Site: Codable, Equatable, Sendable {
        public var zoom: Double?
        public var darkMode: DarkMode?
        public var javaScript: Bool?
        public var camera: Permission?
        public var microphone: Permission?

        var isEmpty: Bool { self == Site() }
    }

    public private(set) var sites: [String: Site] = [:]
    @ObservationIgnored private let file: SealedFile?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(directory: URL?, keys: KeyStore = KeychainKeyStore()) {
        file = directory.map {
            SealedFile(url: $0.appendingPathComponent("sites.sealed"), keyName: "sites", purpose: "dev.arcclone.sites.v1", keys: keys)
        }
    }

    public func load() async {
        guard let file else { return }
        do {
            if let data = try await file.read() { sites = try JSONDecoder().decode([String: Site].self, from: data) }
        } catch {
            Log.app.error("Site settings could not be decrypted; starting fresh: \(String(describing: error), privacy: .public)")
            file.delete()
        }
    }

    /// `www.example.com` and `example.com` share settings.
    nonisolated static func key(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), url?.scheme == "https" || url?.scheme == "http" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func site(for url: URL?) -> Site { Self.key(for: url).flatMap { sites[$0] } ?? Site() }

    public func update(_ url: URL?, _ change: (inout Site) -> Void) {
        guard let key = Self.key(for: url) else { return }
        var site = sites[key] ?? Site()
        change(&site)
        sites[key] = site.isEmpty ? nil : site
        scheduleSave()
    }

    public func reset(_ key: String) {
        sites[key] = nil
        scheduleSave()
    }

    public func removeAll() {
        sites.removeAll()
        scheduleSave()
    }

    // MARK: Effective values (site value, else the default from Settings)

    public func zoom(for url: URL?) -> Double {
        site(for: url).zoom ?? Self.defaultZoom
    }

    public func darkMode(for url: URL?) -> DarkMode {
        site(for: url).darkMode ?? Self.defaultDarkMode
    }

    public func allowsJavaScript(for url: URL?) -> Bool {
        site(for: url).javaScript ?? true
    }

    public func permission(_ kind: KeyPath<Site, Permission?>, for url: URL?) -> Permission {
        site(for: url)[keyPath: kind] ?? .ask
    }

    static var defaultZoom: Double {
        let stored = UserDefaults.standard.double(forKey: Preferences.Key.defaultZoom)
        return stored > 0 ? stored : 1
    }

    static var defaultDarkMode: DarkMode {
        UserDefaults.standard.string(forKey: Preferences.Key.defaultDarkMode).flatMap(DarkMode.init(rawValue:)) ?? .standard
    }

    private func scheduleSave() {
        guard let file else { return }
        saveTask?.cancel()
        let snapshot = sites
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                do {
                    if snapshot.isEmpty { file.delete() } else { try await file.write(JSONEncoder().encode(snapshot)) }
                } catch {
                    Log.app.error("Site settings save failed: \(String(describing: error), privacy: .public)")
                }
            }.value
        }
    }
}
