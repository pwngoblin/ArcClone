import Foundation

/// An extension background's console, for diagnosing extensions that can't be inspected. With
/// Settings → General → Show features for web developers on, Lily's worker shim forwards the
/// background's `console.error/warn/info/log` over a native-messaging name Lily answers itself
/// (`applicationIdentifier`). Lines are logged at debug level, which isn't kept on disk: they show
/// only while someone runs `log stream --level debug`. Off, the shim stops forwarding after its
/// first question.
enum ExtensionConsole {
    static let applicationIdentifier = "dev.lily.console"

    struct Line: Decodable, Equatable {
        enum Action: String, Decodable { case enabled, log }
        enum Level: String, Decodable { case error, warn, info, log }
        let action: Action
        let level: Level?
        let text: String?
    }

    /// Answers the shim: whether to forward (`enabled`), or logs one line (`log`).
    static func handle(_ message: Any, extensionName: String, enabled: Bool) throws -> Any? {
        let line = try decode(message)
        switch line.action {
        case .enabled:
            return enabled
        case .log:
            guard enabled, let level = line.level, let text = line.text else { return nil }
            Log.extensions.debug("\(extensionName, privacy: .public) console.\(level.rawValue, privacy: .public): \(text, privacy: .public)")
            return nil
        }
    }

    static func decode(_ message: Any) throws -> Line {
        guard JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message),
              data.count <= 8 * 1024, var line = try? JSONDecoder().decode(Line.self, from: data) else {
            throw ExtensionConsoleError()
        }
        if let text = line.text { line = Line(action: line.action, level: line.level, text: String(text.prefix(2_000))) }
        return line
    }

    struct ExtensionConsoleError: LocalizedError {
        var errorDescription: String? { "Invalid console line" }
    }
}
