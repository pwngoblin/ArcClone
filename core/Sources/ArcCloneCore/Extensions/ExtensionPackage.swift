import CryptoKit
import Foundation

/// A web extension's files, read into memory from a folder, a .zip or a Chrome Web Store .crx, so
/// they can be audited and pinned before anything runs. Reading never launches a helper (`unzip`)
/// and never follows links: archives are parsed here with hard limits on entry count and size,
/// and every path is checked so nothing can land outside the extension's own folder.
struct ExtensionPackage: Sendable, Equatable {
    static let maxEntries = 5_000
    static let maxFileBytes = 50_000_000
    static let maxTotalBytes = 200_000_000

    struct Invalid: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Relative path → contents.
    let files: [String: Data]

    /// SHA-256 over every path and its contents, in path order. Stored (sealed) when the extension
    /// is pinned and checked before each load, so a changed file is never run.
    var contentHash: String {
        var hasher = SHA256()
        for path in files.keys.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(SHA256.hash(data: files[path]!)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var manifest: Data? { files["manifest.json"] }

    init(files: [String: Data]) throws {
        // Archives often wrap everything in one top-level folder.
        var files = files
        if files["manifest.json"] == nil {
            let tops = Set(files.keys.compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
            if tops.count == 1, let top = tops.first, files["\(top)/manifest.json"] != nil {
                files = Dictionary(uniqueKeysWithValues: files.map { (String($0.key.dropFirst(top.count + 1)), $0.value) })
            }
        }
        guard files["manifest.json"] != nil else { throw Invalid(reason: "There's no manifest.json, so this isn't a web extension.") }
        self.files = files
    }

    // MARK: Reading

    /// A folder, .zip or .crx chosen by the user.
    static func read(_ url: URL) throws -> ExtensionPackage {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw Invalid(reason: "Links can't be added as extensions.") }
        if values.isDirectory == true { return try readFolder(url) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxTotalBytes else { throw Invalid(reason: "The file is too large.") }
        return try ExtensionPackage(files: unzip(crxPayload(data) ?? data))
    }

    static func readFolder(_ root: URL) throws -> ExtensionPackage {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            throw Invalid(reason: "The folder couldn't be read.")
        }
        var files: [String: Data] = [:]
        var total = 0
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw Invalid(reason: "The folder contains links, which aren't allowed in extensions.") }
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let path = String(full.dropFirst(base.count + 1))
            if path.hasPrefix(".") || path.contains("/.") { continue } // .git, .DS_Store
            guard let safe = sanitized(path) else { throw Invalid(reason: "A file has a name that isn't allowed: \(path)") }
            let size = values.fileSize ?? 0
            total += size
            guard files.count < maxEntries, size <= maxFileBytes, total <= maxTotalBytes else { throw Invalid(reason: "The extension is too large.") }
            files[safe] = try Data(contentsOf: url)
        }
        return try ExtensionPackage(files: files)
    }

    /// The zip inside a .crx (Chrome Web Store package): `Cr24`, a version, then signature headers.
    /// The store's signature isn't relied on; the audit and the pinned hash are what's trusted.
    static func crxPayload(_ data: Data) -> Data? {
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else { return nil }
        let version = uint32(data, 4)
        let start: Int
        switch version {
        case 3: start = 12 + Int(uint32(data, 8))
        case 2: start = 16 + Int(uint32(data, 8)) + Int(uint32(data, 12))
        default: return nil
        }
        guard start < data.count else { return nil }
        return Data(data[(data.startIndex + start)...])
    }

    /// A zip archive (stored or deflated entries; no encryption, no zip64, no links).
    static func unzip(_ archive: Data) throws -> [String: Data] {
        let zip = Data(archive) // zero-based indices
        let bad = Invalid(reason: "The archive is damaged or uses an unsupported format.")
        guard zip.count >= 22 else { throw bad }
        // End of central directory: the last record, possibly followed by a comment.
        var eocd = -1
        var index = zip.count - 22
        while index >= max(0, zip.count - 22 - 65_535) {
            if uint32(zip, index) == 0x0605_4b50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw bad }
        let count = Int(uint16(zip, eocd + 10))
        let directoryOffset = Int(uint32(zip, eocd + 16))
        guard count <= maxEntries, uint32(zip, eocd + 16) != 0xFFFF_FFFF, directoryOffset < zip.count else { throw bad }

        var files: [String: Data] = [:]
        var total = 0
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= zip.count, uint32(zip, cursor) == 0x0201_4b50 else { throw bad }
            let flags = uint16(zip, cursor + 8)
            let method = uint16(zip, cursor + 10)
            let crc = uint32(zip, cursor + 16)
            let compressedSize = Int(uint32(zip, cursor + 20))
            let size = Int(uint32(zip, cursor + 24))
            let nameLength = Int(uint16(zip, cursor + 28))
            let extraLength = Int(uint16(zip, cursor + 30))
            let commentLength = Int(uint16(zip, cursor + 32))
            let unixMode = uint32(zip, cursor + 38) >> 16
            let localOffset = Int(uint32(zip, cursor + 42))
            guard cursor + 46 + nameLength <= zip.count,
                  let name = String(data: zip[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else { throw bad }
            cursor += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") { continue }
            // Checked before anything is skipped, so `../x` is refused rather than quietly dropped.
            guard let path = sanitized(name) else { throw Invalid(reason: "A file has a name that isn't allowed: \(name)") }
            // Same files a folder import keeps (no hidden files), so a pinned copy re-reads identically.
            if path.hasPrefix("__MACOSX/") || path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            guard flags & 0x1 == 0 else { throw Invalid(reason: "Encrypted archives aren't supported.") }
            guard unixMode & 0o170000 != 0o120000 else { throw Invalid(reason: "The archive contains links, which aren't allowed in extensions.") }
            total += size
            guard size <= maxFileBytes, total <= maxTotalBytes else { throw Invalid(reason: "The extension is too large.") }

            guard localOffset + 30 <= zip.count, uint32(zip, localOffset) == 0x0403_4b50 else { throw bad }
            let dataStart = localOffset + 30 + Int(uint16(zip, localOffset + 26)) + Int(uint16(zip, localOffset + 28))
            guard dataStart + compressedSize <= zip.count else { throw bad }
            let raw = zip[dataStart..<(dataStart + compressedSize)]
            let contents: Data
            switch method {
            case 0: contents = Data(raw)
            case 8:
                // Apple's "zlib" algorithm is raw DEFLATE, which is what zip uses.
                guard let inflated = try? (Data(raw) as NSData).decompressed(using: .zlib) as Data else { throw bad }
                contents = inflated
            default: throw Invalid(reason: "The archive uses an unsupported compression method.")
            }
            guard contents.count == size, CRC32.checksum(contents) == crc else { throw bad }
            guard files[path] == nil else { throw Invalid(reason: "The archive lists \(path) twice.") }
            files[path] = contents
        }
        return files
    }

    /// A relative path with no way out of the extension folder; nil when it's absolute, has `..`,
    /// empty parts, backslashes or control characters.
    static func sanitized(_ raw: String) -> String? {
        var path = raw
        while path.hasPrefix("./") { path.removeFirst(2) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || Sanitize.isInvisibleControl($0) }) else { return nil }
        return path
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + $1]) << (8 * UInt32($1)) }
    }

    // MARK: Pinning

    /// Writes the files into `folder` (created owner-only), replacing anything there.
    func write(to folder: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (path, contents) in files {
            let target = folder.appendingPathComponent(path)
            guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw Invalid(reason: "A file has a name that isn't allowed: \(path)") }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try contents.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        var root = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }
}

/// CRC-32 (IEEE), as zip uses, to catch damaged or doctored archive entries.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
