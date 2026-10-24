import Foundation

/// Locates the non-Swift components (the injection scripts) at runtime.
///
/// Packaged builds only ever use `<App>.app/Contents/Resources/Lily` (see scripts/bundle.sh),
/// which code signing seals. Development builds try, in order:
///   1. `LILY_ROOT` environment variable (repo root or bundle resource root)
///   2. Walking up from this source file / the executable to find the repository
///   3. Current working directory and its parent
public struct AppPaths: Sendable {
    public let root: URL

    public var injections: URL { root.appendingPathComponent("injections", isDirectory: true) }
    public var injectionManifest: URL { injections.appendingPathComponent("manifest.json") }

    public var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Lily", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// This file's path, used to find the repository in development builds. Release builds embed
    /// nothing: a #filePath literal would put the builder's home folder (and username) in the binary.
    #if DEBUG
    public static let developmentSourceFile = #filePath
    #else
    public static let developmentSourceFile = ""
    #endif

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func isRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("injections/manifest.json").path)
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               sourceFile: String = AppPaths.developmentSourceFile,
                               packagedResources: URL? = AppInfo.isPackaged ? Bundle.main.resourceURL : nil) -> AppPaths {
        if let packagedResources {
            let root = packagedResources.appendingPathComponent("Lily", isDirectory: true)
            if !isRoot(root) { Log.app.error("Bundle resources missing at \(root.path, privacy: .public)") }
            return AppPaths(root: root)
        }
        var candidates: [URL] = []
        if let env = environment["LILY_ROOT"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        candidates.append(contentsOf: ancestors(of: URL(fileURLWithPath: sourceFile)))
        candidates.append(contentsOf: ancestors(of: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])))
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd)
        candidates.append(cwd.deletingLastPathComponent())

        for candidate in candidates where isRoot(candidate) {
            return AppPaths(root: candidate)
        }
        Log.app.error("Could not locate Lily resources; set LILY_ROOT. Falling back to cwd.")
        return AppPaths(root: cwd)
    }

    private static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.deletingLastPathComponent()
        for _ in 0..<8 {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
    }
}
