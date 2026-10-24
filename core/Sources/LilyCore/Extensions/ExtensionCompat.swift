import Foundation

/// Extensions built for Chrome often use chrome.* APIs that WebKit's extension runtime doesn't
/// have (`notifications`, `privacy`, `management`, `idle`, `downloads`, some events), and a call at
/// startup kills their background: 1Password's worker throws on `chrome.notifications.onClicked`,
/// so its popup never gets an answer. When an extension is added, Lily puts its first-party
/// worker shim (`injections/extension-worker-compat.js`) in front of the background, which gives
/// those calls inert stand-ins. It's added before the audit and the hash, so the shim is part of
/// the reviewed, pinned copy, and the extension's own files are untouched.
enum ExtensionCompat {
    static let folder = "lily-compat"
    static let shimPath = "\(folder)/worker-compat.js"
    static let entryPath = "\(folder)/background.js"

    /// `package` with the shim in front of its background, or unchanged when it has none (or a
    /// background page, which can include scripts itself) or its manifest can't be rewritten.
    static func apply(to package: ExtensionPackage, shim: Data) -> ExtensionPackage {
        guard package.files[shimPath] == nil, let data = package.manifest,
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var background = manifest["background"] as? [String: Any] else { return package }
        var files = package.files
        if let worker = background["service_worker"] as? String {
            guard let path = ExtensionPackage.sanitized(worker), isPlainPath(path), files[path] != nil else { return package }
            // A module worker imports in order; a classic one runs importScripts in order.
            let entry = background["type"] as? String == "module"
                ? "import '/\(shimPath)';\nimport '/\(path)';\n"
                : "importScripts('/\(shimPath)', '/\(path)');\n"
            files[entryPath] = Data(entry.utf8)
            background["service_worker"] = entryPath
        } else if let scripts = background["scripts"] as? [String], !scripts.isEmpty {
            background["scripts"] = [shimPath] + scripts
        } else {
            return package
        }
        files[shimPath] = shim
        manifest["background"] = background
        guard let rewritten = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]),
              let patched = try? ExtensionPackage(files: files.merging(["manifest.json": rewritten]) { $1 }) else { return package }
        return patched
    }

    /// Paths that are safe to write into the entry script's string literals.
    private static func isPlainPath(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-/".unicodeScalars.contains($0) }
    }
}
