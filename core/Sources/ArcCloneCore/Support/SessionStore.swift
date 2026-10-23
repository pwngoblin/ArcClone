import Foundation

/// Persists the window session (open tabs) encrypted at rest; see `SealedFile`. Tab URLs can carry
/// tokens in their query strings, so they never touch disk in plaintext.
public actor SessionStore {
    public struct Session: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public var url: URL
            public var title: String
            public var pinned: Bool
            /// Security-scoped bookmark for file:// tabs; without it the sandbox can't reopen them.
            public var bookmark: Data?
            public var space: UUID?

            public init(url: URL, title: String, pinned: Bool, bookmark: Data? = nil, space: UUID? = nil) {
                self.url = url
                self.title = title
                self.pinned = pinned
                self.bookmark = bookmark
                self.space = space
            }
        }

        public var tabs: [Entry]
        public var activeIndex: Int?
        public var spaces: [Space]?
        public var currentSpace: UUID?
    }

    private let file: SealedFile
    /// Plaintext session.json written by 0.1.0; migrated on first load, then deleted.
    private let legacyURL: URL

    public init(directory: URL, keys: KeyStore = KeychainKeyStore()) {
        file = SealedFile(url: directory.appendingPathComponent("session.sealed"), keyName: "session",
                          purpose: "dev.arcclone.session.v1", keys: keys)
        legacyURL = directory.appendingPathComponent("session.json")
    }

    public func load() async -> Session? {
        do {
            if let data = try await file.read() { return try JSONDecoder().decode(Session.self, from: data) }
        } catch {
            // Unreadable (tampered, or the key was removed): start fresh rather than fail launch.
            Log.app.error("Session could not be decrypted; discarding it: \(String(describing: error), privacy: .public)")
            file.delete()
        }
        guard let legacy = try? Data(contentsOf: legacyURL), let session = try? JSONDecoder().decode(Session.self, from: legacy) else { return nil }
        await save(session)
        try? FileManager.default.removeItem(at: legacyURL)
        return session
    }

    public func save(_ session: Session) async {
        do {
            try await file.write(JSONEncoder().encode(session))
        } catch {
            Log.app.error("Session save failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func clear() {
        file.delete()
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
