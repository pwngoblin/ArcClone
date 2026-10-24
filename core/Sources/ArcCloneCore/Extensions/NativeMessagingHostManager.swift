import Foundation

/// Native messaging (`chrome.runtime.connectNative` / `sendNativeMessage`) for extensions.
///
/// ArcClone deliberately doesn't bridge extensions to desktop helper binaries. Commercial password
/// managers (1Password, Bitwarden, …) ship helpers that only accept a hard-coded, signed list of
/// browsers, so they reject ArcClone however the pipes are set up, and launching other apps'
/// binaries from the App Sandbox would widen the attack surface for nothing. Every request is
/// answered at once with a clear error the extension can handle, so password managers fall back
/// to their own in-extension sign-in, storage and web flows instead of hanging on a host that
/// never answers. No process is ever started here.
actor NativeMessagingHostManager {
    static let shared = NativeMessagingHostManager()

    struct Unsupported: LocalizedError, Equatable {
        let application: String
        var errorDescription: String? {
            "ArcClone doesn't connect extensions to desktop apps (\(application)). Sign in within the extension instead."
        }
    }

    private var reported = Set<String>()

    /// The answer to a one-off native message or a port connection: always `Unsupported`.
    func request(application: String?, extensionName: String) -> Unsupported {
        let name = String((application ?? "native host").prefix(100))
        if reported.insert("\(extensionName)|\(name)").inserted {
            Log.extensions.notice("Native messaging to \(name, privacy: .public) refused for \(extensionName, privacy: .private): not supported")
        }
        return Unsupported(application: name)
    }
}
