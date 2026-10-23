import AppKit
import CryptoKit
import Foundation
import Testing
@testable import ArcCloneCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Unit tests never touch the real Keychain.
actor InMemoryKeyStore: KeyStore {
    private var keys: [String: SymmetricKey] = [:]
    func key(named name: String) -> SymmetricKey {
        if let key = keys[name] { return key }
        let key = SymmetricKey(size: .bits256)
        keys[name] = key
        return key
    }
    func deleteKey(named name: String) { keys[name] = nil }
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arcclone-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct InsecureDataStorageTests {
    let sample = SessionStore.Session(tabs: [.init(url: URL(string: "https://bank.test/account?token=s3cret")!, title: "Bank", pinned: true)],
                                      activeIndex: 0)

    @Test func sessionIsEncryptedOwnerOnlyAndExcludedFromBackup() async throws {
        let dir = try temporaryDirectory()
        let store = SessionStore(directory: dir, keys: InMemoryKeyStore())
        await store.save(sample)
        let file = dir.appendingPathComponent("session.sealed")
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("s3cret".utf8)) == nil && raw.range(of: Data("bank.test".utf8)) == nil)
        #expect(await store.load() == sample)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func tamperedOrForeignSessionsAreRejected() async throws {
        let dir = try temporaryDirectory()
        await SessionStore(directory: dir, keys: InMemoryKeyStore()).save(sample)
        // A different key (another machine, or a reset Keychain) can't read it.
        #expect(await SessionStore(directory: dir, keys: InMemoryKeyStore()).load() == nil)

        let keys = InMemoryKeyStore()
        let store = SessionStore(directory: dir, keys: keys)
        await store.save(sample)
        let file = dir.appendingPathComponent("session.sealed")
        var raw = try Data(contentsOf: file)
        raw[raw.count - 1] ^= 0xFF
        try raw.write(to: file)
        #expect(await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func plaintextLegacySessionIsMigratedAndDeleted() async throws {
        let dir = try temporaryDirectory()
        let legacy = dir.appendingPathComponent("session.json")
        try JSONEncoder().encode(sample).write(to: legacy)
        let store = SessionStore(directory: dir, keys: InMemoryKeyStore())
        #expect(await store.load() == sample)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.sealed").path))
    }

    @Test func ollamaHostCredentialsAreDropped() {
        #expect(AssistantConfiguration.normalizedHost("https://user:pa55@ollama.example").absoluteString == "https://ollama.example")
    }
}

@Suite struct InsecureNetworkTests {
    @Test func publicHTTPIsUpgradedToHTTPS() {
        #expect(HTTPSFirst.upgrade(URL(string: "http://example.com/a?b=c")!, allowed: [])?.absoluteString == "https://example.com/a?b=c")
        #expect(HTTPSFirst.upgrade(URL(string: "http://example.com:80/")!, allowed: [])?.absoluteString == "https://example.com/")
    }

    @Test func privateHostsAndUserExceptionsStayOnHTTP() {
        for raw in ["http://localhost:5173", "http://127.0.0.1/", "http://192.168.1.1/", "http://printer.local/", "http://router/", "http://[::1]:8080/"] {
            #expect(HTTPSFirst.upgrade(URL(string: raw)!, allowed: []) == nil, "\(raw)")
        }
        #expect(HTTPSFirst.upgrade(URL(string: "http://legacy.example/")!, allowed: ["legacy.example"]) == nil)
        #expect(HTTPSFirst.upgrade(URL(string: "https://example.com/")!, allowed: []) == nil)
    }

    @Test func assistantRefusesPlaintextHTTPOffThisMac() async {
        #expect(AssistantConfiguration(host: "http://127.0.0.1:11434").transportError == nil)
        #expect(AssistantConfiguration(host: "https://ollama.example").transportError == nil)
        #expect(AssistantConfiguration(host: "http://gpu-box.local:11434").transportError?.code == "ollama_unavailable")
        let assistant = await Assistant(configuration: .init(host: "http://10.0.0.5:11434"))
        await #expect(throws: IPCError.self) { _ = try await assistant.models() }
    }
}

@Suite struct EntitlementAndInjectionTests {
    @Test func entitlementsFileMatchesAllowlist() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("scripts/ArcClone.entitlements"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.app-sandbox"] as? Bool == true)
        let allowed: Set<String> = [
            "com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.user-selected.read-only", "com.apple.security.files.bookmarks.app-scope", "com.apple.security.print",
            "com.apple.security.device.camera", "com.apple.security.device.microphone", "com.apple.security.device.audio-input",
        ]
        #expect(Set(plist.keys).subtracting(allowed).isEmpty, "unexpected: \(Set(plist.keys).subtracting(allowed))")
        #expect(!plist.keys.contains { $0.contains("temporary-exception") || $0.hasPrefix("com.apple.security.cs.") })
    }

    @Test func tamperedBundleFailsIntegrityCheck() async throws {
        let built = repoRoot.appendingPathComponent("build/ArcClone.app")
        guard FileManager.default.fileExists(atPath: built.path) else { return } // needs `make app`
        let dir = try temporaryDirectory()
        let copy = dir.appendingPathComponent("ArcClone.app")
        try FileManager.default.copyItem(at: built, to: copy)
        #expect(await CodeIntegrity.verify(bundleAt: copy) == nil)

        let script = copy.appendingPathComponent("Contents/Resources/ArcClone/injections/modules/runtime.js")
        let handle = try FileHandle(forWritingTo: script)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n;window.__evil = 1;".utf8))
        try handle.close()
        #expect(await CodeIntegrity.verify(bundleAt: copy) != nil)
    }
}

@Suite struct CertificatePinningTests {
    /// Independent check: the reference implementation prepends a fixed ASN.1 header for RSA-2048.
    @Test func rsaSPKIHashMatchesFixedHeaderMethod() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let raw = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let header: [UInt8] = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                               0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00]
        let expected = Data(SHA256.hash(data: Data(header) + raw)).base64EncodedString()
        #expect(CertificatePinning.spkiHash(of: publicKey) == expected)
    }

    @Test func ecSPKIHashMatchesCryptoKitDER() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let secKey = try #require(SecKeyCreateWithData(key.x963Representation as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ] as CFDictionary, nil))
        #expect(CertificatePinning.spkiHash(of: secKey) == Data(SHA256.hash(data: key.derRepresentation)).base64EncodedString())
    }

    @Test func derLengthsUseLongFormAbove127Bytes() {
        #expect(CertificatePinning.der(0x04, Data(count: 5)).prefix(2) == Data([0x04, 0x05]))
        #expect(CertificatePinning.der(0x04, Data(count: 300)).prefix(4) == Data([0x04, 0x82, 0x01, 0x2c]))
    }

    @Test func onlyWellFormedPinsAreAccepted() {
        let good = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(AssistantConfiguration.parsePins("\(good), not-base64, \(Data(count: 16).base64EncodedString())") == [good])
    }
}

@Suite @MainActor struct ClipboardTests {
    @Test func sensitiveCopiesAreConcealedAndTransient() {
        let board = NSPasteboard(name: NSPasteboard.Name("arcclone-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        Clipboard.copy("https://private.example/", sensitive: true, to: board)
        #expect(board.string(forType: .string) == "https://private.example/")
        #expect(board.types?.contains(Clipboard.concealed) == true && board.types?.contains(Clipboard.transient) == true)
        Clipboard.copy("https://public.example/", sensitive: false, to: board)
        #expect(board.types?.contains(Clipboard.concealed) == false)
    }
}
