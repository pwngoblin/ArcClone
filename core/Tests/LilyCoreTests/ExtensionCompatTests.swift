import Foundation
import Testing
@testable import LilyCore

private let shim = Data("(() => {})();\n".utf8)

private func package(_ manifest: String, _ files: [String: String] = [:]) throws -> ExtensionPackage {
    try ExtensionPackage(files: files.mapValues { Data($0.utf8) }.merging(["manifest.json": Data(manifest.utf8)]) { $1 })
}

private func background(_ package: ExtensionPackage) throws -> [String: Any] {
    let data = try #require(package.manifest)
    let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(manifest["background"] as? [String: Any])
}

@Suite struct ExtensionCompatTests {
    @Test func moduleWorkersImportTheShimFirst() throws {
        let original = try package(#"{"name": "T", "version": "1", "manifest_version": 3, "background": {"service_worker": "bg/main.js", "type": "module"}}"#,
                                   ["bg/main.js": "chrome.notifications.onClicked.addListener(() => {});"])
        let patched = ExtensionCompat.apply(to: original, shim: shim)
        #expect(try background(patched)["service_worker"] as? String == ExtensionCompat.entryPath)
        #expect(try background(patched)["type"] as? String == "module")
        #expect(String(decoding: try #require(patched.files[ExtensionCompat.entryPath]), as: UTF8.self)
                == "import '/lily-compat/worker-compat.js';\nimport '/bg/main.js';\n")
        #expect(patched.files[ExtensionCompat.shimPath] == shim)
        // The extension's own files are untouched.
        #expect(patched.files["bg/main.js"] == original.files["bg/main.js"])
        #expect(ExtensionManifest.parse(patched)?.name == "T")
    }

    @Test func classicWorkersAndBackgroundScripts() throws {
        let classic = ExtensionCompat.apply(to: try package(#"{"name": "T", "version": "1", "manifest_version": 3, "background": {"service_worker": "sw.js"}}"#, ["sw.js": ""]), shim: shim)
        #expect(String(decoding: try #require(classic.files[ExtensionCompat.entryPath]), as: UTF8.self)
                == "importScripts('/lily-compat/worker-compat.js', '/sw.js');\n")
        let scripts = ExtensionCompat.apply(to: try package(#"{"name": "T", "version": "1", "manifest_version": 2, "background": {"scripts": ["a.js", "b.js"]}}"#, ["a.js": "", "b.js": ""]), shim: shim)
        #expect(try background(scripts)["scripts"] as? [String] == [ExtensionCompat.shimPath, "a.js", "b.js"])
        #expect(scripts.files[ExtensionCompat.entryPath] == nil)
    }

    @Test func leavesOtherExtensionsAlone() throws {
        for manifest in [#"{"name": "T", "version": "1", "manifest_version": 3}"#,
                         #"{"name": "T", "version": "1", "manifest_version": 2, "background": {"page": "bg.html"}}"#,
                         #"{"name": "T", "version": "1", "manifest_version": 3, "background": {"service_worker": "missing.js"}}"#] {
            let original = try package(manifest)
            #expect(ExtensionCompat.apply(to: original, shim: shim) == original)
        }
    }

    @Test func pathsThatCantBeQuotedSafelyAreLeftAlone() throws {
        // A quote in the worker path would break out of the entry's string literal.
        let original = try package(#"{"name": "T", "version": "1", "manifest_version": 3, "background": {"service_worker": "x');evil('.js", "type": "module"}}"#,
                                   ["x');evil('.js": ""])
        #expect(ExtensionCompat.apply(to: original, shim: shim) == original)
    }

    @Test func applyingTwiceChangesNothing() throws {
        let once = ExtensionCompat.apply(to: try package(#"{"name": "T", "version": "1", "manifest_version": 3, "background": {"service_worker": "sw.js", "type": "module"}}"#, ["sw.js": ""]), shim: shim)
        #expect(ExtensionCompat.apply(to: once, shim: shim) == once)
    }

    @Test func theShippedShimPassesTheAudit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../injections/extension-worker-compat.js").standardizedFileURL
        let source = try Data(contentsOf: root)
        let patched = ExtensionCompat.apply(to: try package(#"{"name": "T", "version": "1", "manifest_version": 3, "background": {"service_worker": "sw.js", "type": "module"}}"#, ["sw.js": ""]), shim: source)
        let audit = ExtensionAudit.scan(patched)
        #expect(audit.findings.filter { $0.severity >= .warning }.isEmpty, "\(audit.findings)")
    }
}
