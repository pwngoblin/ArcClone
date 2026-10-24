import CryptoKit
import Foundation
import Security
import Testing
@testable import LilyCore

/// Builds signed CRX3 packages in memory, the way the Chrome Web Store does.
private struct CRXBuilder {
    enum Signer {
        case rsa(SecKey)
        case ecdsa(P256.Signing.PrivateKey)

        static func newRSA() -> Signer {
            .rsa(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!)
        }

        var spki: Data {
            switch self {
            case .rsa(let key): CertificatePinning.subjectPublicKeyInfo(of: SecKeyCopyPublicKey(key)!)!
            case .ecdsa(let key): key.publicKey.derRepresentation
            }
        }

        var id: String { CRX3.extensionID(fromHash: Data(SHA256.hash(data: spki))) }

        func sign(_ message: Data) -> Data {
            switch self {
            case .rsa(let key): SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
            case .ecdsa(let key): try! key.signature(for: message).derRepresentation
            }
        }
    }

    var signers: [Signer]
    /// The ID written into the signed header; the first signer's by default.
    var crxID: Data?
    /// Stands in for the Web Store, which countersigns every package.
    var publisher: Signer? = testPublisher

    func build(_ payload: Data) -> Data {
        let id = crxID ?? Data(SHA256.hash(data: signers[0].spki).prefix(16))
        let signers = signers + [publisher].compactMap { $0 }
        let signedData = field(1, id)
        var message = Data("CRX3 SignedData\u{0}".utf8) + le32(UInt32(signedData.count)) + signedData
        message += payload
        var header = Data()
        for signer in signers {
            let tag: UInt64 = if case .rsa = signer { 2 } else { 3 }
            header += field(tag, field(1, signer.spki) + field(2, signer.sign(message)))
        }
        header += field(10_000, signedData)
        return Data("Cr24".utf8) + le32(3) + le32(UInt32(header.count)) + header + payload
    }

    private func field(_ number: UInt64, _ bytes: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }

    private func varint(_ value: UInt64) -> Data {
        var value = value, out = Data()
        repeat {
            out.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return out
    }

    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
}

private let testPublisherKey = P256.Signing.PrivateKey()
private var testPublisher: CRXBuilder.Signer { .ecdsa(testPublisherKey) }
private let testPublisherHash = Data(SHA256.hash(data: testPublisher.spki))

private func verify(_ crx: Data, expectedID: String) throws -> Data {
    try CRX3.verifiedPayload(crx, expectedID: expectedID, publisherKeyHash: testPublisherHash)
}

private func extensionZip() -> Data {
    var zip = ZipBuilder()
    zip.add("manifest.json", #"{"name": "Store Test", "version": "1.0", "manifest_version": 3, "permissions": ["storage"]}"#)
    zip.add("background.js", "chrome.storage.local.set({ ok: true });")
    return zip.build()
}

@Suite struct ChromeWebStoreTests {
    private let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    @Test func acceptsStoreLinksAndBareIDs() {
        #expect(ChromeWebStore.extensionID(from: id) == id)
        #expect(ChromeWebStore.extensionID(from: "  \(id.uppercased())\n") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/1password/\(id)") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/1password/\(id)?hl=en&pli=1") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/\(id)") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chrome.google.com/webstore/detail/1password/\(id)") == id)
    }

    @Test func refusesAnythingElse() {
        #expect(ChromeWebStore.extensionID(from: "") == nil)
        #expect(ChromeWebStore.extensionID(from: String(id.dropLast())) == nil)
        #expect(ChromeWebStore.extensionID(from: "zeblfdkhhhdcdjpifhhbdiojplfjncoa") == nil) // letters a–p only
        #expect(ChromeWebStore.extensionID(from: "http://chromewebstore.google.com/detail/x/\(id)") == nil)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com.evil.example/detail/x/\(id)") == nil)
        #expect(ChromeWebStore.extensionID(from: "https://evil.example/detail/x/\(id)") == nil)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/search/\(id)") == nil)
    }

    @Test func downloadURLIsGooglesOnDemandEndpoint() throws {
        let url = try #require(ChromeWebStore.downloadURL(for: id))
        #expect(url.absoluteString == "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(ChromeWebStore.productVersion())&acceptformat=crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc")
        #expect(ChromeWebStore.downloadURL(for: "not-an-id&x=1") == nil)
    }

    @Test func reportsTheCurrentChromeVersion() {
        func on(_ day: String) -> String { ChromeWebStore.productVersion(on: ISO8601DateFormatter().date(from: day + "T12:00:00Z")!) }
        #expect(on("2023-12-05") == "120.0")
        // Never behind a real stable release (that's what hid 1Password), at most a few ahead,
        // since the four-week cadence skips Chrome's holiday gaps.
        for (day, stable) in [("2025-01-14", 132), ("2025-05-27", 137), ("2025-09-02", 140)] {
            let reported = Int(on(day).dropLast(2))!
            #expect((stable...(stable + 3)).contains(reported), "\(day): \(reported)")
        }
        #expect(on("2020-01-01") == "120.0") // a wrong clock never reports something ancient
    }

    @Test func extensionIDsUseChromesEncoding() {
        #expect(CRX3.extensionID(fromHash: Data(repeating: 0, count: 16)) == String(repeating: "a", count: 32))
        #expect(CRX3.extensionID(fromHash: Data([0x0F, 0xF0] + Array(repeating: 0, count: 14))) == "appa" + String(repeating: "a", count: 28))
    }

    @Test func verifiedRSAPackageUnpacksAndAudits() async throws {
        let signer = CRXBuilder.Signer.newRSA()
        let crx = CRXBuilder(signers: [signer]).build(extensionZip())
        let inspected = try await ExtensionLoader.inspect(crx: crx, expectedID: signer.id, publisherKeyHash: testPublisherHash)
        #expect(inspected.manifest?.name == "Store Test")
        #expect(!inspected.audit.isBlocked)
    }

    @Test func verifiesECDSAAndExtraPublisherSignatures() throws {
        let developer = CRXBuilder.Signer.ecdsa(P256.Signing.PrivateKey())
        let crx = CRXBuilder(signers: [developer, .newRSA()]).build(extensionZip())
        #expect(try verify(crx, expectedID: developer.id) == extensionZip())
    }

    @Test func requiresTheStoresCountersignature() {
        let signer = CRXBuilder.Signer.newRSA()
        let unpublished = CRXBuilder(signers: [signer], publisher: nil).build(extensionZip())
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(unpublished, expectedID: signer.id) }
        // Signed by someone, but not by the real Web Store key.
        let published = CRXBuilder(signers: [signer]).build(extensionZip())
        #expect(throws: ExtensionPackage.Invalid.self) { try CRX3.verifiedPayload(published, expectedID: signer.id) }
        #expect(CRX3.webStorePublisherKeyHash.count == 32)
    }

    @Test func refusesADifferentExtension() {
        let crx = CRXBuilder(signers: [.newRSA()]).build(extensionZip())
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(crx, expectedID: id) }
    }

    @Test func refusesTamperedContents() {
        let signer = CRXBuilder.Signer.newRSA()
        var crx = CRXBuilder(signers: [signer]).build(extensionZip())
        crx[crx.count - 30] ^= 0xFF
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(crx, expectedID: signer.id) }
    }

    @Test func refusesAnIDNoSignerOwns() {
        // Validly signed, but the claimed ID belongs to a key that didn't sign it.
        let signer = CRXBuilder.Signer.newRSA()
        let claimed = Data(SHA256.hash(data: Data("someone else".utf8)).prefix(16))
        let crx = CRXBuilder(signers: [signer], crxID: claimed).build(extensionZip())
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(crx, expectedID: CRX3.extensionID(fromHash: claimed)) }
    }

    @Test func refusesOneBadSignatureAmongGoodOnes() {
        let developer = CRXBuilder.Signer.newRSA()
        // The ECDSA proof goes last, so its signature ends right before the signed-data field.
        var crx = CRXBuilder(signers: [developer, testPublisher, .ecdsa(P256.Signing.PrivateKey())], publisher: nil).build(extensionZip())
        #expect(throws: Never.self) { try verify(crx, expectedID: developer.id) }
        // Corrupt the last byte of the ECDSA proof's signature, just before the signed-data field
        // (3-byte tag, length, then crx_id's tag, length and 16 bytes).
        let signedDataField = 3 + 1 + 2 + 16
        let headerEnd = 12 + (Int(crx[8]) | Int(crx[9]) << 8)
        crx[headerEnd - signedDataField - 1] ^= 0x01
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(crx, expectedID: developer.id) }
    }

    @Test func refusesUnsignedV2AndNonZipPackages() {
        let signer = CRXBuilder.Signer.newRSA()
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(Data("Cr24".utf8) + Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + extensionZip(), expectedID: signer.id) }
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(CRXBuilder(signers: [signer]).build(Data("not a zip".utf8)), expectedID: signer.id) }
        #expect(throws: ExtensionPackage.Invalid.self) { try verify(extensionZip(), expectedID: signer.id) }
        #expect(ExtensionPackage.crxPayload(Data("Cr24".utf8) + Data([3, 0, 0, 0, 0, 0, 0, 0]) + Data("not a zip at all".utf8)) == nil)
    }

    @Test func malformedHeadersDontCrash() {
        for bytes: [UInt8] in [[0x12], [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F], [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], [0x0B]] {
            #expect(throws: ExtensionPackage.Invalid.self) { try CRX3.parseHeader(Data(bytes)) }
        }
    }

    @Test func storeInstallsRememberTheirID() throws {
        let record = InstalledExtension(id: "x", enabled: true, grantedPermissions: [], grantedPatterns: [], storeID: id)
        let decoded = try JSONDecoder().decode(InstalledExtension.self, from: JSONEncoder().encode(record))
        #expect(decoded.storeID == id)
        // Records saved before store installs existed still decode.
        let legacy = #"{"id": "y", "enabled": true, "grantedPermissions": [], "grantedPatterns": []}"#
        #expect(try JSONDecoder().decode(InstalledExtension.self, from: Data(legacy.utf8)).storeID == nil)
    }
}
