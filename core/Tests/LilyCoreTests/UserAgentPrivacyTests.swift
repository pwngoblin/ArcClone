import Foundation
import Testing
@testable import LilyCore

/// Lily presents as this Mac's Safari, so its user agent is one many people send.
@Suite struct UserAgentPrivacyTests {
    private func plist(_ version: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        try (["CFBundleShortVersionString": version] as NSDictionary).write(to: url)
        return url
    }

    private let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)

    @Test func usesTheInstalledSafariVersion() throws {
        #expect(WebViewFactory.safariApplicationName(safariInfo: try plist("27.0.1"), system: macOS27) == "Version/27.0.1 Safari/605.1.15")
    }

    @Test func fallsBackToTheSafariThisMacOSShipsWith() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/Info.plist")
        #expect(WebViewFactory.safariApplicationName(safariInfo: missing, system: macOS27) == "Version/27.0 Safari/605.1.15")
        #expect(WebViewFactory.safariApplicationName(safariInfo: missing, system: .init(majorVersion: 15, minorVersion: 6, patchVersion: 0))
                == "Version/18.0 Safari/605.1.15")
        // Something that isn't a version number never reaches the user agent.
        #expect(WebViewFactory.safariApplicationName(safariInfo: try plist("27 (beta); x"), system: macOS27) == "Version/27.0 Safari/605.1.15")
    }

    @Test func matchesThisMacsSafari() throws {
        guard let installed = NSDictionary(contentsOf: URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist"))?["CFBundleShortVersionString"] as? String else { return }
        #expect(WebViewFactory.safariApplicationName() == "Version/\(installed) Safari/605.1.15")
    }
}
