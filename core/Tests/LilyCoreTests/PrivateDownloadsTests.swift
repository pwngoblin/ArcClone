import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct PrivateDownloadsTests {
    private func item(_ name: String, private isPrivate: Bool) -> DownloadManager.Item {
        var item = DownloadManager.Item(filename: name)
        item.state = .finished
        item.source = URL(string: "https://files.example/\(name)")
        item.isPrivate = isPrivate
        return item
    }

    @Test func privateDownloadsAreListedOnlyInPrivateWindows() {
        let downloads = DownloadManager()
        downloads.insertForTesting(item("report.pdf", private: false))
        downloads.insertForTesting(item("secret.pdf", private: true))
        #expect(downloads.items(privateWindow: false).map(\.filename) == ["report.pdf"])
        #expect(downloads.items(privateWindow: true).map(\.filename) == ["secret.pdf"])

        downloads.clearFinished(privateWindow: false) // a regular window's Clear leaves private ones
        #expect(downloads.items(privateWindow: true).count == 1)
        downloads.forgetPrivate()                      // the last private window closed
        #expect(downloads.items.isEmpty)
    }

    @Test func privateFilesDontKeepWhereTheyCameFrom() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // What macOS attaches to a downloaded file: "Where from" and a quarantine record with the address.
        let whereFrom = try PropertyListSerialization.data(fromPropertyList: ["https://files.example/secret.pdf"], format: .binary, options: 0)
        _ = whereFrom.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, whereFrom.count, 0, 0) }
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Lily", kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                                       kLSQuarantineDataURLKey as String: URL(string: "https://files.example/secret.pdf")!,
                                       kLSQuarantineOriginURLKey as String: URL(string: "https://files.example/")!]
        try url.setResourceValues(values)

        DownloadManager.scrubOrigin(file)

        #expect(getxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0) < 0)
        let quarantine = try #require(try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(quarantine[kLSQuarantineDataURLKey as String] == nil && quarantine[kLSQuarantineOriginURLKey as String] == nil)
        #expect(quarantine[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String) // still quarantined
    }
}
