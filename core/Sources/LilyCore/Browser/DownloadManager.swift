import AppKit
import Observation
import WebKit

/// Every download, app-wide: saved to ~/Downloads under a sanitized, unique name, with live
/// progress for the sidebar's Downloads popover. Downloads from private windows are listed only
/// in private windows, forgotten when the last one closes, and their files don't keep the address
/// they came from (`scrubOrigin`).
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
        /// From a private window: never listed in regular windows.
        public var isPrivate = false

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

    /// The downloads a window shows: private windows' own, or everyone else's.
    public func items(privateWindow: Bool) -> [Item] { items.filter { $0.isPrivate == privateWindow } }
    public func activeCount(privateWindow: Bool) -> Int { items(privateWindow: privateWindow).filter(\.isActive).count }

    /// Combined progress of a window's active downloads, for the button's ring.
    public func overallFraction(privateWindow: Bool) -> Double? {
        let active = items(privateWindow: privateWindow).filter(\.isActive)
        guard !active.isEmpty, active.allSatisfy({ $0.totalBytes > 0 }) else { return active.isEmpty ? nil : 0 }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        return Double(active.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(max(total, 1))
    }

    /// Called by tabs when a navigation turns into a download.
    func track(_ download: WKDownload, privately: Bool = false) {
        download.delegate = self
        var item = Item(filename: "Download")
        item.source = download.originalRequest?.url
        item.isPrivate = privately
        items.insert(item, at: 0)
        downloads[item.id] = download
        ids[ObjectIdentifier(download)] = item.id
        let id = item.id
        progressObservations[id] = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.progressed(id, received: received, total: total) }
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
        if let item = items.first(where: { $0.id == id }), item.isPrivate, let file = item.destination { Self.scrubOrigin(file) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = finish(download) else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        if let resumeData { self.resumeData[id] = resumeData }
        update(id) { $0.state = cancelled ? .cancelled : .failed(Sanitize.errorMessage(error)) }
        Log.web.error("Download failed: \(error.localizedDescription, privacy: .private)")
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
        let privately = item.isPrivate
        if let data = resumeData.removeValue(forKey: id) {
            webView.resumeDownload(fromResumeData: data) { [weak self] download in self?.track(download, privately: privately) }
        } else if let source = item.source {
            webView.startDownload(using: URLRequest(url: source)) { [weak self] download in self?.track(download, privately: privately) }
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

    /// A window's Clear button: its own finished downloads.
    public func clearFinished(privateWindow: Bool) {
        let gone = Set(items.filter { !$0.isActive && $0.isPrivate == privateWindow }.map(\.id))
        items.removeAll { gone.contains($0.id) }
        gone.forEach { resumeData[$0] = nil }
    }

    /// Clear Browsing Data: every finished download, private and not.
    public func clearFinished() {
        items.removeAll { !$0.isActive }
        resumeData.removeAll()
    }

    /// Tests: a finished download without WebKit.
    func insertForTesting(_ item: Item) { items.insert(item, at: 0) }

    /// The last private window closed: nothing it downloaded stays listed.
    public func forgetPrivate() {
        let gone = Set(items.filter { $0.isPrivate && !$0.isActive }.map(\.id))
        items.removeAll { gone.contains($0.id) }
        gone.forEach { resumeData[$0] = nil }
    }

    /// macOS records where a downloaded file came from in two places on the file: the
    /// "Where from" metadata (Finder's Get Info) and its quarantine record. For a private download
    /// both lose the address; the quarantine itself stays, so Gatekeeper still checks the file.
    nonisolated static func scrubOrigin(_ file: URL) {
        _ = removexattr(file.path, "com.apple.metadata:kMDItemWhereFroms", 0)
        var url = file
        guard var quarantine = (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties else { return }
        quarantine.removeValue(forKey: kLSQuarantineDataURLKey as String)
        quarantine.removeValue(forKey: kLSQuarantineOriginURLKey as String)
        var values = URLResourceValues()
        values.quarantineProperties = quarantine
        do { try url.setResourceValues(values) } catch { Log.web.error("Couldn't remove a private download's origin") }
    }

    // MARK: Helpers

    @ObservationIgnored private var lastProgressUpdate: [UUID: Date] = [:]

    /// At most ~4 UI updates a second per download (WebKit reports every chunk), plus the last one.
    private func progressed(_ id: UUID, received: Int64, total: Int64) {
        let now = Date()
        if total > 0, received < total, let last = lastProgressUpdate[id], now.timeIntervalSince(last) < 0.25 { return }
        lastProgressUpdate[id] = now
        update(id) { $0.receivedBytes = received; $0.totalBytes = total }
    }

    private func finish(_ download: WKDownload) -> UUID? {
        guard let id = ids.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        downloads[id] = nil
        progressObservations[id] = nil
        lastProgressUpdate[id] = nil
        return id
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    nonisolated static func uniqueURL(in directory: URL, name: String) -> URL {
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
