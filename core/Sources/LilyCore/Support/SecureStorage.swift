import CryptoKit
import Foundation
import Security

/// Source of the symmetric key that encrypts app data at rest.
public protocol KeyStore: Sendable {
    func key(named name: String) async throws -> SymmetricKey
    func deleteKey(named name: String) async throws
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String
    public var description: String {
        "Keychain \(operation) failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
    }
}

/// Keeps one 256-bit key per name in the Keychain. Every SecItem call runs on this actor, never on
/// the main thread. Items are device-bound (`…ThisDeviceOnly`) and readable after first unlock so
/// the session can be saved while the screen is locked.
///
/// Uses the data protection keychain when the app is entitled to it (a provisioned build). Without
/// that entitlement the flag is not reliable: on some systems SecItemAdd succeeds but files the item
/// in the login keychain with an ACL any process can read. So unentitled builds use the login
/// keychain explicitly, where the default ACL limits the item to the creating app. Login-keychain items
/// are bound to the code signature that created them, and touching another build's item makes macOS
/// prompt the user, so there the account name carries a hash of this build's designated requirement:
/// stable across updates for Developer ID builds, unique per build for ad-hoc ones.
public actor KeychainKeyStore: KeyStore {
    public static let service = "dev.lily.browser.storage"
    private var useDataProtectionKeychain = true
    private let identityTag: String

    public init() {
        identityTag = Self.designatedRequirementTag()
        useDataProtectionKeychain = Self.isEntitledToDataProtectionKeychain()
    }

    /// Login keychain ACL that trusts only this app; any other process must ask the user.
    /// (SecAccess is the login keychain's own ACL API; the data protection keychain doesn't use it.)
    @available(macOS, deprecated: 10.10)
    static func selfOnlyAccess() -> SecAccess? {
        var me: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Lily data encryption key" as CFString, [me] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// The data protection keychain needs an application identifier or access groups, which only
    /// provisioned builds carry.
    static func isEntitledToDataProtectionKeychain() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return ["com.apple.application-identifier", "keychain-access-groups"].contains {
            SecTaskCopyValueForEntitlement(task, $0 as CFString, nil) != nil
        }
    }

    static func designatedRequirementTag() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return "unsigned" }
        return SHA256.hash(data: Data((text as String).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Key bytes only live in `SymmetricKey`, which zeroes its storage when released. The
    /// intermediate copies made for the Keychain are wiped as soon as the call returns.
    public func key(named name: String) throws -> SymmetricKey {
        if let stored = try readKey(name) { return stored }
        let newKey = SymmetricKey(size: .bits256)
        var data = newKey.withUnsafeBytes { Data($0) }
        defer { data.resetBytes(in: 0..<data.count) }
        let status: OSStatus = {
            var attributes = baseQuery(name)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrLabel as String] = "Lily data encryption key"
            if !useDataProtectionKeychain, let access = Self.selfOnlyAccess() {
                attributes[kSecAttrAccess as String] = access
            }
            return SecItemAdd(attributes as CFDictionary, nil)
        }() // the dictionary (and its reference to `data`) is gone before the wipe
        switch status {
        case errSecSuccess:
            return newKey
        case errSecDuplicateItem:
            // Another launch created it first; use theirs so both agree on one key.
            guard let existing = try readKey(name) else { throw KeychainError(status: status, operation: "add") }
            return existing
        case errSecMissingEntitlement where useDataProtectionKeychain:
            useDataProtectionKeychain = false
            return try key(named: name)
        default:
            throw KeychainError(status: status, operation: "add")
        }
    }

    public func deleteKey(named name: String) throws {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        case errSecMissingEntitlement where useDataProtectionKeychain:
            useDataProtectionKeychain = false
            try deleteKey(named: name)
        default: throw KeychainError(status: status, operation: "delete")
        }
    }

    /// Reads the stored key straight into a `SymmetricKey` and wipes the copy made on the way.
    private func readKey(_ name: String) throws -> SymmetricKey? {
        guard var data = try read(name) else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        return SymmetricKey(data: data)
    }

    private func read(_ name: String) throws -> Data? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // Security's buffer is immutable and can't be wiped without unsafe pointers; drop our
            // reference at once so it's freed, and wipe the copy the caller turns into a key.
            guard let buffer = result as? Data, buffer.count == 32 else { throw KeychainError(status: errSecDecode, operation: "read") }
            result = nil
            return buffer
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement where useDataProtectionKeychain:
            useDataProtectionKeychain = false
            return try read(name)
        case errSecInteractionNotAllowed:
            // Locked: report it and leave the item alone; it becomes readable after unlock.
            throw KeychainError(status: status, operation: "read")
        default:
            throw KeychainError(status: status, operation: "read")
        }
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: useDataProtectionKeychain ? name : "\(name).\(identityTag)",
        ]
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

/// A small file encrypted with AES-GCM (random nonce per write, authenticated with a purpose
/// string), written atomically with file protection, owner-only permissions and no backups.
public struct SealedFile: Sendable {
    public let url: URL
    public let keyName: String
    public let purpose: String
    public let keys: KeyStore

    public init(url: URL, keyName: String, purpose: String, keys: KeyStore) {
        self.url = url
        self.keyName = keyName
        self.purpose = purpose
        self.keys = keys
    }

    public func write(_ plaintext: Data) async throws {
        let key = try await keys.key(named: keyName)
        guard let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Data(purpose.utf8)).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Self.writeProtected(sealed, to: url)
    }

    /// Returns nil when the file doesn't exist. Throws when it exists but fails authentication.
    public func read() async throws -> Data? {
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        let key = try await keys.key(named: keyName)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(purpose.utf8))
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}
