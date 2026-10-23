import AppKit
import Observation
import WebKit

/// Every download, app-wide: saved to ~/Downloads under a sanitized, unique name, with live
/// progress for the sidebar's Downloads popover.
@MainActor @Observable
public final class DownloadManager: NSObject, WKDownloadDelegate {
    public static let shared = DownloadManager()

    public struct Item: Identifiable, Equatable {
        public enum State: Equatable { case downloading, finished, failed(String), cancelled }

        public let id = UUID()
        public var filename: String
        public var destination: URL?
        public var source: URL?
        public var receivedBytes: Int64 = 0
        public var totalBytes: Int64 = -1
        public var state: State = .downloading
        public var startedAt = Date()

        public var fraction: Double? { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : nil }
        public var isActive: Bool { state == .downloading }
    }

    public private(set) var items: [Item] = []
    /// Bumped whenever a download starts, so the sidebar button can bounce.
    public private(set) var startCount = 0

    @ObservationIgnored private var downloads: [UUID: WKDownload] = [:]
    @ObservationIgnored private var ids: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var resumeData: [UUID: Data] = [:]

    public var activeCount: Int { items.filter(\.isActive).count }

    /// Combined progress of active downloads, for the button's ring.
    public var overallFraction: Double? {
        let active = items.filter(\.isActive)
        guard !active.isEmpty, active.allSatisfy({ $0.totalBytes > 0 }) else { return active.isEmpty ? nil : 0 }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        return Double(active.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(max(total, 1))
    }

    /// Called by tabs when a navigation turns into a download.
    func track(_ download: WKDownload) {
        download.delegate = self
        var item = Item(filename: "Download")
        item.source = download.originalRequest?.url
        items.insert(item, at: 0)
        downloads[item.id] = download
        ids[ObjectIdentifier(download)] = item.id
        let id = item.id
        progressObservations[id] = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.update(id) { $0.receivedBytes = received; $0.totalBytes = total } }
        }
        startCount += 1
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let url = Self.uniqueURL(in: folder, name: Sanitize.filename(suggestedFilename))
        if let id = ids[ObjectIdentifier(download)] {
            update(id) {
                $0.filename = url.lastPathComponent
                $0.destination = url
                $0.totalBytes = response.expectedContentLength
            }
        }
        Log.web.info("Downloading to \(url.path, privacy: .private)")
        return url
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let id = finish(download) else { return }
        update(id) { $0.state = .finished; if $0.totalBytes > 0 { $0.receivedBytes = $0.totalBytes } }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = finish(download) else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        if let resumeData { self.resumeData[id] = resumeData }
        update(id) { $0.state = cancelled ? .cancelled : .failed(error.localizedDescription) }
        Log.web.error("Download failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Actions

    public func cancel(_ id: UUID) {
        downloads[id]?.cancel { [weak self] data in
            Task { @MainActor in if let data { self?.resumeData[id] = data } }
        }
    }

    /// Resumes from where it stopped when WebKit kept resume data, otherwise starts over.
    public func retry(_ id: UUID, in webView: WKWebView?) {
        guard let webView, let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        if let data = resumeData.removeValue(forKey: id) {
            webView.resumeDownload(fromResumeData: data) { [weak self] download in self?.track(download) }
        } else if let source = item.source {
            webView.startDownload(using: URLRequest(url: source)) { [weak self] download in self?.track(download) }
        }
    }

    public func reveal(_ id: UUID) {
        guard let url = items.first(where: { $0.id == id })?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens with the default app; macOS still applies Gatekeeper to quarantined files.
    public func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state == .finished, let url = item.destination else { return }
        NSWorkspace.shared.open(url)
    }

    public func remove(_ id: UUID) {
        guard items.first(where: { $0.id == id })?.isActive == false else { return }
        items.removeAll { $0.id == id }
        resumeData[id] = nil
    }

    public func clearFinished() {
        items.removeAll { !$0.isActive }
        resumeData.removeAll()
    }

    // MARK: Helpers

    private func finish(_ download: WKDownload) -> UUID? {
        guard let id = ids.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        downloads[id] = nil
        progressObservations[id] = nil
        return id
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
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
