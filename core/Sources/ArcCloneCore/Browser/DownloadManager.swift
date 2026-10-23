import WebKit

/// Saves downloads to ~/Downloads with a unique filename and reveals them when done.
@MainActor
public final class DownloadManager: NSObject, WKDownloadDelegate {
    public static let shared = DownloadManager()

    private var destinations: [ObjectIdentifier: URL] = [:]

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let url = Self.uniqueURL(in: downloads, name: Sanitize.filename(suggestedFilename))
        destinations[ObjectIdentifier(download)] = url
        Log.web.info("Downloading to \(url.path, privacy: .private)")
        return url
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        Log.web.error("Download failed: \(error.localizedDescription, privacy: .public)")
    }

    static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return candidate
    }
}
