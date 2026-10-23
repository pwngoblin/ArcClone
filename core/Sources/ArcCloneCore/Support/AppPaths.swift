import Foundation

/// Locates the non-Swift components (injections, built UI, agent bridge) at runtime.
///
/// Packaged builds only ever use `<App>.app/Contents/Resources/ArcClone` (see scripts/bundle.sh),
/// which code signing seals. Development builds try, in order:
///   1. `ARCCLONE_ROOT` environment variable (repo root or bundle resource root)
///   2. Walking up from this source file / the executable to find the repository
///   3. Current working directory and its parent
public struct AppPaths: Sendable {
    public let root: URL

    public var injections: URL { root.appendingPathComponent("injections", isDirectory: true) }
    public var injectionManifest: URL { injections.appendingPathComponent("manifest.json") }
    public var uiDist: URL { root.appendingPathComponent("ui/dist", isDirectory: true) }
    public var agentBridgeMain: URL { root.appendingPathComponent("agent-bridge/src/main.js") }

    public var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ArcClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func isRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("injections/manifest.json").path)
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               sourceFile: String = #filePath,
                               packagedResources: URL? = AppInfo.isPackaged ? Bundle.main.resourceURL : nil) -> AppPaths {
        if let packagedResources {
            let root = packagedResources.appendingPathComponent("ArcClone", isDirectory: true)
            if !isRoot(root) { Log.app.error("Bundle resources missing at \(root.path, privacy: .public)") }
            return AppPaths(root: root)
        }
        var candidates: [URL] = []
        if let env = environment["ARCCLONE_ROOT"], !env.isEmpty {
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
        Log.app.error("Could not locate ArcClone resources; set ARCCLONE_ROOT. Falling back to cwd.")
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
