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
    /// Reads a folder, .zip or .crx and audits it.
    @ExtensionActor
    static func inspect(_ url: URL) throws -> InspectedExtension {
        let package = try ExtensionPackage.read(url)
        return InspectedExtension(package: package, manifest: ExtensionManifest.parse(package), audit: ExtensionAudit.scan(package))
    }

    /// A CRX3 downloaded from the Chrome Web Store: signatures and ID verified, then unpacked and audited.
    @ExtensionActor
    static func inspect(crx data: Data, expectedID: String, publisherKeyHash: Data = CRX3.webStorePublisherKeyHash) throws -> InspectedExtension {
        let package = try ExtensionPackage(files: ExtensionPackage.unzip(CRX3.verifiedPayload(data, expectedID: expectedID, publisherKeyHash: publisherKeyHash)))
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
}
