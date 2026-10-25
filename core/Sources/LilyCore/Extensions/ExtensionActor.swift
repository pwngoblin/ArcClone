import Foundation

/// Where extension files are read, audited and hashed: off the main thread, one job at a time, so
/// adding or verifying a large extension never stalls the UI. (WebKit's extension controller is
/// main-thread only, so the runtime itself stays on the main actor and calls in here for file work.)
@globalActor
actor ExtensionActor {
    static let shared = ExtensionActor()
}

/// What adding an extension needs to know about its files.
struct InspectedExtension: Sendable {
    let package: ExtensionPackage
    let manifest: ExtensionManifest?
    let audit: ExtensionAudit
}

enum ExtensionLoader {
    /// Reads a folder, .zip or .crx, adds the worker shim (`ExtensionCompat`) and audits it.
    @ExtensionActor
    static func inspect(_ url: URL, compat: Data? = nil) throws -> InspectedExtension {
        inspected(try ExtensionPackage.read(url), compat: compat)
    }

    /// A CRX3 downloaded from the Chrome Web Store: signatures and ID verified, then unpacked and audited.
    @ExtensionActor
    static func inspect(crx data: Data, expectedID: String, publisherKeyHash: Data = CRX3.webStorePublisherKeyHash,
                        compat: Data? = nil) throws -> InspectedExtension {
        let payload = try CRX3.verifiedPayload(data, expectedID: expectedID, publisherKeyHash: publisherKeyHash)
        return inspected(try ExtensionPackage(files: ExtensionPackage.unzip(payload)), compat: compat)
    }

    /// The shim goes in before the audit and the hash, so it's part of what's reviewed and pinned.
    private static func inspected(_ package: ExtensionPackage, compat: Data?) -> InspectedExtension {
        let package = compat.map { ExtensionCompat.apply(to: package, shim: $0) } ?? package
        return InspectedExtension(package: package, manifest: ExtensionManifest.parse(package), audit: ExtensionAudit.scan(package))
    }

    /// The pinned copy, re-read only if it's exactly what was approved.
    @ExtensionActor
    static func verifiedPackage(at folder: URL, expectedHash: String) -> ExtensionPackage? {
        guard let package = try? ExtensionPackage.readFolder(folder), package.contentHash == expectedHash else { return nil }
        return package
    }

    @ExtensionActor
    static func pin(_ package: ExtensionPackage, to folder: URL) throws {
        try package.write(to: folder)
    }

    /// Removes pinned copies under `root` other than `kept`. Only Lily's own folders (named by a
    /// UUID) are touched.
    @ExtensionActor
    static func removeFolders(in root: URL, except kept: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where UUID(uuidString: name) != nil && !kept.contains(name) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            Log.extensions.notice("Removed an extension copy no longer in the installed list")
        }
    }
}
