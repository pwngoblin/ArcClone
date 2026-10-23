import WebKit

/// Loads the injection manifest and turns each module into a `WKUserScript` that runs
/// in the isolated `ArcInjections` content world. Scripts with host restrictions are
/// wrapped in a guard, since WKUserScript has no URL matching of its own.
@MainActor
public final class ScriptRegistry {
    public struct CompiledScript: Sendable {
        public let id: String
        public let source: String
        public let injectionTime: InjectionManifest.Script.InjectionTime
        public let mainFrameOnly: Bool
        public let matches: [String]
    }

    public static let messageHandlerName = "arc"

    public let manifestURL: URL
    public private(set) var manifest: InjectionManifest
    public private(set) var scripts: [CompiledScript] = []
    public let contentWorld: WKContentWorld

    public init(manifestURL: URL) throws {
        self.manifestURL = manifestURL
        self.manifest = try InjectionManifest.load(from: manifestURL)
        self.contentWorld = WKContentWorld.world(name: manifest.contentWorld)
        try compile()
    }

    /// Re-reads the manifest and module files (used by Develop > Reload Injections).
    public func reload() throws {
        let fresh = try InjectionManifest.load(from: manifestURL)
        guard fresh.contentWorld == manifest.contentWorld else {
            throw IPCError.malformed("Changing the content world requires a restart")
        }
        manifest = fresh
        try compile()
    }

    private func compile() throws {
        let base = manifestURL.deletingLastPathComponent()
        scripts = try manifest.scripts.map { entry in
            let url = base.appendingPathComponent(entry.file)
            let code = try String(contentsOf: url, encoding: .utf8)
            return CompiledScript(id: entry.id,
                                  source: Self.wrap(code, id: entry.id, file: entry.file, matches: entry.matches),
                                  injectionTime: entry.injectionTime,
                                  mainFrameOnly: entry.mainFrameOnly,
                                  matches: entry.matches)
        }
        Log.scripts.info("Compiled \(self.scripts.count) injection scripts")
    }

    /// Builds the final source: host guard + module + sourceURL for Web Inspector.
    nonisolated public static func wrap(_ code: String, id: String, file: String, matches: [String]) -> String {
        let sourceURL = "\n//# sourceURL=arc-injection://\(file)\n"
        if matches == ["*"] { return code + sourceURL }
        let patterns = JSONValue.array(matches.map(JSONValue.string)).jsonString()
        return """
        (function () {
          var host = (location.hostname || "").toLowerCase();
          var patterns = \(patterns);
          var ok = patterns.some(function (p) {
            p = p.toLowerCase();
            if (p === "*") return true;
            if (p.indexOf("*.") === 0) return host.slice(-(p.length - 1)) === p.slice(1);
            return host === p;
          });
          if (!ok) return;
        \(code)
        })();
        """ + sourceURL
    }

    public func install(into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        for script in scripts {
            let time: WKUserScriptInjectionTime = script.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd
            controller.addUserScript(WKUserScript(source: script.source, injectionTime: time,
                                                  forMainFrameOnly: script.mainFrameOnly, in: contentWorld))
        }
    }
}
