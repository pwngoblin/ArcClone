import SwiftUI

/// Site icons, without telling sites what's in your history. Only a page that's open in a tab may
/// fetch its icon (you're on that site already); everywhere else (History, suggestions, sleeping
/// and restored tabs) shows the icon Lily kept from your last visit, or a globe, and never asks
/// the network. A request for `/favicon.ico` would tell the site, your network and its DNS that
/// it's in your history every time a list was drawn, and every restored tab's site at each launch.
///
/// Kept icons are small (at most 32 px), one per site, encrypted at rest like history
/// (`favicons.sealed`), at most `maxSites`, forgotten with history and by Clear Browsing Data.
/// Icons seen in private windows are shown there but never kept.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()
    static let maxSites = 600
    static let maxIconBytes = 16_000

    private struct Kept: Codable {
        var png: Data
        var seen: Date
    }

    /// Icons fetched this session, private windows' included (memory only).
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private var kept: [String: Kept] = [:]
    /// Sites whose open page was asked for its icon this session (once is enough).
    private var fetched: Set<String> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var file: SealedFile?
    private var saveTask: Task<Void, Never>?
    private let session: URLSession

    /// The shared loader's session: no cookies, cache or credentials. Tests pass their own.
    static var ephemeral: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        return config
    }

    init(configuration: URLSessionConfiguration = FaviconLoader.ephemeral) {
        session = URLSession(configuration: configuration)
    }

    /// `directory: nil` keeps icons in memory only (the self-test).
    func load(directory: URL?, keys: KeyStore = KeychainKeyStore()) async {
        file = directory.map { SealedFile(url: $0.appendingPathComponent("favicons.sealed"), keyName: "favicons", purpose: "dev.lily.favicons.v1", keys: keys) }
        guard let file else { return }
        do {
            if let data = try await file.read() { kept = try JSONDecoder().decode([String: Kept].self, from: data) }
        } catch {
            Log.app.error("Kept site icons failed authentication; starting empty")
            kept = [:]
        }
    }

    static func site(_ page: URL?) -> String? {
        guard let page, let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return page.host?.lowercased()
    }

    /// The icon for `page`'s site from this session or a past visit; never touches the network.
    func icon(forPage page: URL?) -> NSImage? {
        guard let site = Self.site(page) else { return nil }
        if let image = cache.object(forKey: site as NSString) { return image }
        guard let entry = kept[site], let image = NSImage(data: entry.png) else { return nil }
        cache.setObject(image, forKey: site as NSString)
        return image
    }

    /// Fetches `icon` for an open page on `page`'s site; `remember: false` (private windows) shows
    /// it without keeping it.
    func fetch(_ icon: URL, forPage page: URL?, remember: Bool) async -> NSImage? {
        guard let site = Self.site(page) else { return nil }
        if fetched.contains(site) { return self.icon(forPage: page) }
        fetched.insert(site)
        if let task = inFlight[icon] { return await task.value }
        let task = Task<NSImage?, Never> { [session] in
            guard Sanitize.isFetchableFavicon(icon),
                  let (data, response) = try? await session.data(from: icon),
                  (response as? HTTPURLResponse)?.statusCode ?? 0 < 400, data.count < 512_000 else { return nil }
            return NSImage(data: data)
        }
        inFlight[icon] = task
        let image = await task.value
        inFlight[icon] = nil
        guard let image else { return nil }
        cache.setObject(image, forKey: site as NSString)
        if remember, let png = Self.smallPNG(image), png.count <= Self.maxIconBytes {
            kept[site] = Kept(png: png, seen: Date())
            if kept.count > Self.maxSites {
                for (old, _) in kept.sorted(by: { $0.value.seen < $1.value.seen }).prefix(kept.count - Self.maxSites) { kept[old] = nil }
            }
            scheduleSave()
        }
        return image
    }

    /// History forgot something: kept icons would still say which sites were in it.
    func forget(_ forgotten: History.Forgotten) {
        switch forgotten {
        case .all:
            kept.removeAll()
            fetched.removeAll()
            cache.removeAllObjects()
            saveTask?.cancel()
            file?.delete()
            return
        case .since(let date): kept = kept.filter { $0.value.seen < date }
        case .before(let cutoff): kept = kept.filter { $0.value.seen >= cutoff }
        case .sites(let sites):
            for site in sites { kept[site] = nil; cache.removeObject(forKey: site as NSString) }
        }
        scheduleSave()
    }

    /// At most 32 px: what the sidebar and lists draw, a few KB each.
    private static func smallPNG(_ image: NSImage) -> Data? {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func scheduleSave() {
        guard let file else { return }
        saveTask?.cancel()
        let snapshot = kept
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            do { try await file.write(data) } catch { Log.app.error("Saving site icons failed") }
        }
    }
}

/// A site's icon. `fetch` is the icon address of a page that's open right now (it may be
/// downloaded); without it, only an icon kept from a visit is shown.
struct FaviconView: View {
    let page: URL?
    var fetch: URL? = nil
    var remember = true
    var size: CGFloat = 16
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: [page, fetch]) {
            image = FaviconLoader.shared.icon(forPage: page)
            // An open page refreshes its site's kept icon once a session; nothing else fetches.
            if let fetch, let fresh = await FaviconLoader.shared.fetch(fetch, forPage: page, remember: remember) { image = fresh }
        }
    }
}
