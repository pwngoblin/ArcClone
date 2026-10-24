import AppKit

/// Registers Lily with Launch Services as the handler for http/https links.
/// Only a packaged .app can be chosen; `swift run` builds have no bundle to register.
@MainActor
enum DefaultBrowser {
    static var isAvailable: Bool {
        AppInfo.isPackaged && Bundle.main.bundleIdentifier != nil
    }

    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS asks the user to confirm the change; the completion reports the outcome.
    static func makeDefault(completion: @escaping @MainActor (Error?) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in
                if let error { return completion(error) }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { error in
                    Task { @MainActor in completion(error) }
                }
            }
        }
    }
}
