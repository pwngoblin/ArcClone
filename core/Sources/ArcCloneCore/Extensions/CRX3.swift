import CryptoKit
import Foundation
import Security

/// Verifies a CRX3 package the way Chrome does before it trusts one fetched from the store:
/// `Cr24`, version 3, a protobuf `CrxFileHeader`, then the zip. Every signature in the header must
/// check out over `"CRX3 SignedData\0" ‖ len ‖ signed_header_data ‖ zip`, and one of the signing
/// keys must hash to the extension ID that was asked for. So a download that was swapped, damaged
/// or is a different extension never reaches the audit.
enum CRX3 {
    static let maxHeaderBytes = 1_000_000
    static let maxProofs = 16

    struct Proof: Equatable {
        let publicKey: Data
        let signature: Data
    }

    struct Header: Equatable {
        var rsa: [Proof] = []
        var ecdsa: [Proof] = []
        var signedData: Data?
    }

    /// The zip inside `data`, once its signatures and ID are verified.
    static func verifiedPayload(_ data: Data, expectedID: String) throws -> Data {
        let crx = Data(data) // zero-based indices
        let bad = ExtensionPackage.Invalid(reason: "The download isn't a valid Chrome extension package.")
        guard crx.count >= 12, crx.prefix(4) == Data("Cr24".utf8) else { throw bad }
        guard uint32(crx, 4) == 3 else { throw ExtensionPackage.Invalid(reason: "Only CRX3 packages from the Chrome Web Store are supported.") }
        let headerLength = Int(uint32(crx, 8))
        guard headerLength <= maxHeaderBytes, 12 + headerLength + 4 <= crx.count else { throw bad }
        let header = try parseHeader(crx[12..<(12 + headerLength)])
        let payload = Data(crx[(12 + headerLength)...])
        guard payload.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else { throw bad }

        guard let signedData = header.signedData, let crxID = try parseCRXID(signedData) else { throw bad }
        guard extensionID(fromHash: crxID) == expectedID else {
            throw ExtensionPackage.Invalid(reason: "The download is a different extension than the one requested.")
        }
        var message = Data("CRX3 SignedData\u{0}".utf8)
        message.append(contentsOf: (0..<4).map { UInt8((UInt32(signedData.count) >> (8 * $0)) & 0xFF) })
        message.append(signedData)
        message.append(payload)

        let forged = ExtensionPackage.Invalid(reason: "The package's signature doesn't match its contents.")
        guard !header.rsa.isEmpty || !header.ecdsa.isEmpty else { throw forged }
        for proof in header.rsa where !verifyRSA(proof, message) { throw forged }
        for proof in header.ecdsa where !verifyECDSA(proof, message) { throw forged }
        // The developer key is what the ID is derived from; it has to be among the signers.
        guard (header.rsa + header.ecdsa).contains(where: { Data(SHA256.hash(data: $0.publicKey).prefix(16)) == crxID }) else { throw forged }
        return payload
    }

    /// Chrome's ID encoding: the first 16 bytes of a SHA-256, one letter a–p per nibble.
    static func extensionID(fromHash hash: Data) -> String {
        String(String.UnicodeScalarView(hash.prefix(16).flatMap { [$0 >> 4, $0 & 0x0F] }.map { Unicode.Scalar(UInt8(ascii: "a") + $0) }))
    }

    // MARK: Protobuf

    static func parseHeader(_ bytes: Data) throws -> Header {
        var header = Header()
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            switch (field, value) {
            case (2, let value?): header.rsa.append(try parseProof(value))
            case (3, let value?): header.ecdsa.append(try parseProof(value))
            case (10_000, let value?): header.signedData = value
            default: continue
            }
            guard header.rsa.count + header.ecdsa.count <= maxProofs else { throw ProtoReader.malformed }
        }
        return header
    }

    private static func parseProof(_ bytes: Data) throws -> Proof {
        var key: Data?, signature: Data?
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            if field == 1 { key = value } else if field == 2 { signature = value }
        }
        guard let key, let signature else { throw ProtoReader.malformed }
        return Proof(publicKey: key, signature: signature)
    }

    /// `SignedData.crx_id`: 16 bytes.
    private static func parseCRXID(_ bytes: Data) throws -> Data? {
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            if field == 1 { return value?.count == 16 ? value : nil }
        }
        return nil
    }

    struct ProtoReader {
        static let malformed = ExtensionPackage.Invalid(reason: "The package header is damaged.")
        private let data: Data
        private var offset = 0

        init(_ data: Data) { self.data = Data(data) }

        /// The next field's number and, for length-delimited fields, its bytes; nil at the end.
        mutating func next() throws -> (UInt64, Data?)? {
            guard offset < data.count else { return nil }
            let tag = try varint()
            switch tag & 0x7 {
            case 0: _ = try varint(); return (tag >> 3, nil)
            case 1: try skip(8); return (tag >> 3, nil)
            case 5: try skip(4); return (tag >> 3, nil)
            case 2:
                let length = try varint()
                guard length <= UInt64(data.count - offset) else { throw Self.malformed }
                let value = data[offset..<(offset + Int(length))]
                offset += Int(length)
                return (tag >> 3, Data(value))
            default: throw Self.malformed
            }
        }

        private mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard offset < data.count else { throw Self.malformed }
                let byte = data[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << UInt64(shift)
                if byte & 0x80 == 0 { return value }
            }
            throw Self.malformed
        }

        private mutating func skip(_ count: Int) throws {
            guard offset + count <= data.count else { throw Self.malformed }
            offset += count
        }
    }

    // MARK: Signatures

    private static func verifyRSA(_ proof: Proof, _ message: Data) -> Bool {
        guard let pkcs1 = rsaPublicKey(fromSPKI: proof.publicKey),
              let key = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyGetBlockSize(key) >= 256 else { return false } // 2048-bit or larger
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, proof.signature as CFData, nil)
    }

    private static func verifyECDSA(_ proof: Proof, _ message: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: proof.publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.signature) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// The PKCS#1 `RSAPublicKey` inside a SubjectPublicKeyInfo, which is what Security wants.
    /// SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { 0, RSAPublicKey } }
    static func rsaPublicKey(fromSPKI spki: Data) -> Data? {
        let rsaEncryption = Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        let der = Data(spki)
        guard let outer = derElement(der, at: 0, tag: 0x30), outer.end == der.count,
              let algorithm = derElement(der, at: outer.start, tag: 0x30),
              der[algorithm.start..<algorithm.end].starts(with: rsaEncryption),
              let bits = derElement(der, at: algorithm.end, tag: 0x03), bits.end == outer.end,
              bits.end > bits.start, der[bits.start] == 0 else { return nil }
        return Data(der[(bits.start + 1)..<bits.end])
    }

    /// The content range of the DER element at `offset`, if it has `tag` and fits.
    private static func derElement(_ der: Data, at offset: Int, tag: UInt8) -> (start: Int, end: Int)? {
        guard offset + 2 <= der.count, der[offset] == tag else { return nil }
        var start = offset + 2
        var length = Int(der[offset + 1])
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), start + count <= der.count else { return nil }
            length = der[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard start + length <= der.count else { return nil }
        return (start, start + length)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }
}
