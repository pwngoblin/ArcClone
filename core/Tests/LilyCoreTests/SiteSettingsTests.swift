import Foundation
import SwiftUI
import Testing
@testable import LilyCore

@Suite @MainActor struct SiteSettingsTests {
    let url = URL(string: "https://www.example.com/page")!

    @Test func hostsShareSettingsWithAndWithoutWWW() {
        #expect(SiteSettings.key(for: url) == "example.com")
        #expect(SiteSettings.key(for: URL(string: "http://EXAMPLE.com")!) == "example.com")
        #expect(SiteSettings.key(for: URL(string: "file:///tmp/a.html")!) == nil)
    }

    @Test func emptySitesAreDroppedAndDefaultsApply() {
        let settings = SiteSettings(directory: nil, keys: InMemoryKeyStore())
        #expect(settings.zoom(for: url) == SiteSettings.defaultZoom)
        #expect(settings.darkMode(for: url) == .standard && settings.allowsJavaScript(for: url))
        settings.update(url) { $0.zoom = 1.25; $0.darkMode = .forced }
        #expect(settings.zoom(for: URL(string: "https://example.com")!) == 1.25)
        #expect(settings.darkMode(for: url) == .forced)
        settings.update(url) { $0.zoom = nil; $0.darkMode = nil }
        #expect(settings.sites.isEmpty)
    }

    @Test func permissionsDefaultToAsk() {
        let settings = SiteSettings(directory: nil, keys: InMemoryKeyStore())
        #expect(settings.permission(\.camera, for: url) == .ask)
        settings.update(url) { $0.camera = .deny; $0.microphone = .allow }
        #expect(settings.permission(\.camera, for: url) == .deny && settings.permission(\.microphone, for: url) == .allow)
    }

    @Test func defaultsComeFromPreferences() {
        UserDefaults.standard.set(1.5, forKey: Preferences.Key.defaultZoom)
        UserDefaults.standard.set("dark", forKey: Preferences.Key.defaultDarkMode)
        defer {
            UserDefaults.standard.removeObject(forKey: Preferences.Key.defaultZoom)
            UserDefaults.standard.removeObject(forKey: Preferences.Key.defaultDarkMode)
        }
        let settings = SiteSettings(directory: nil, keys: InMemoryKeyStore())
        #expect(settings.zoom(for: url) == 1.5 && settings.darkMode(for: url) == .dark)
    }

    @Test func persistsEncrypted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-sites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = InMemoryKeyStore()
        let settings = SiteSettings(directory: dir, keys: keys)
        settings.update(url) { $0.zoom = 1.1 }
        await settings.flush()
        let raw = try Data(contentsOf: dir.appendingPathComponent("sites.sealed"))
        #expect(raw.range(of: Data("example.com".utf8)) == nil)
        let reloaded = SiteSettings(directory: dir, keys: keys)
        await reloaded.load()
        #expect(reloaded.zoom(for: url) == 1.1)
    }

    @Test func httpsFirstCanBeTurnedOff() {
        let insecure = URL(string: "http://example.com/")!
        #expect(HTTPSFirst.upgrade(insecure) != nil)
        UserDefaults.standard.set(false, forKey: Preferences.Key.httpsFirst)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.Key.httpsFirst) }
        #expect(HTTPSFirst.upgrade(insecure) == nil)
    }
}

@Suite struct AppearanceTests {
    @Test func hexColorsRoundTrip() {
        for hex in AppearanceStyle.presets { #expect(Color(hex: hex).hexString == hex) }
    }

    @Test func darkModeScriptIsRegisteredForEveryMainFrame() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try InjectionManifest.load(from: root.appendingPathComponent("injections/manifest.json"))
        let entry = try #require(manifest.scripts.first { $0.id == "dark-mode" })
        #expect(entry.mainFrameOnly && entry.matches == ["*"])
    }
}
