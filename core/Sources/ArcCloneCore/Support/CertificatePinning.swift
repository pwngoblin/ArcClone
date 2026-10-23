import CryptoKit
import Foundation
import Security

/// SPKI SHA-256 pinning for connections the app makes itself (a remote Ollama). Pins are checked
/// only after the system has validated the chain, hostname, expiry and revocation: a pin narrows
/// trust, it never widens it. Websites are validated by WebKit's own TLS stack instead.
public enum CertificatePinning {
    /// Base64 SHA-256 of the SubjectPublicKeyInfo, the same value as
    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
    public static func spkiHash(of certificate: SecCertificate) -> String? {
        SecCertificateCopyKey(certificate).flatMap(spkiHash(of:))
    }

    public static func spkiHash(of key: SecKey) -> String? {
        subjectPublicKeyInfo(of: key).map { Data(SHA256.hash(data: $0)).base64EncodedString() }
    }

    /// `SecKeyCopyExternalRepresentation` returns the bare key (X9.63 point or PKCS#1), not SPKI,
    /// so the DER wrapper is rebuilt here; hashing the bare key would never match standard pins.
    static func subjectPublicKeyInfo(of key: SecKey) -> Data? {
        guard let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String else { return nil }
        if type == kSecAttrKeyTypeECSECPrimeRandom as String {
            switch raw.count {
            case 65: return try? P256.Signing.PublicKey(x963Representation: raw).derRepresentation
            case 97: return try? P384.Signing.PublicKey(x963Representation: raw).derRepresentation
            case 133: return try? P521.Signing.PublicKey(x963Representation: raw).derRepresentation
            default: return nil
            }
        }
        if type == kSecAttrKeyTypeRSA as String {
            // SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { 0 unused bits, RSAPublicKey } }
            let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
            return der(0x30, algorithm + der(0x03, Data([0x00]) + raw))
        }
        return nil
    }

    static func der(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            let length = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0) }.drop { $0 == 0 }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        return out + content
    }

    /// System trust first (chain, hostname, expiry, revocation, Certificate Transparency); then, when
    /// pins are configured, at least one certificate in the chain must carry a pinned key.
    static func evaluate(_ trust: SecTrust, pins: Set<String>) -> Bool {
        guard SecTrustEvaluateWithError(trust, nil) else { return false }
        guard !pins.isEmpty else { return true }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return chain.contains { spkiHash(of: $0).map(pins.contains) ?? false }
    }

    /// Reads the SPKI hashes a server presents today (leaf first, then its issuers), after the system
    /// has validated the chain. Used by "Pin Current Certificate"; the leaf and its issuer together
    /// give a primary and a backup pin.
    public static func currentPins(for url: URL) async throws -> [String] {
        let recorder = ChainRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        _ = try await session.data(for: request)
        let pins = recorder.pins
        guard !pins.isEmpty else { throw IPCError("tls_unavailable", "\(url.host ?? "The server") did not present a certificate") }
        return pins
    }

    private final class ChainRecorder: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var pins: [String] { lock.withLock { recorded } }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            lock.withLock { recorded = chain.compactMap(CertificatePinning.spkiHash(of:)) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}

/// URLSession delegate that enforces `CertificatePinning.evaluate`. Never accepts a chain the
/// system rejects, and offers no override.
final class PinningSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    let pins: Set<String>

    init(pins: Set<String>) {
        self.pins = pins
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard CertificatePinning.evaluate(trust, pins: pins) else {
            Log.agent.error("TLS validation or certificate pin failed for \(challenge.protectionSpace.host, privacy: .private)")
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
