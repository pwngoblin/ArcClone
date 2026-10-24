import SwiftUI

/// Loads favicons through an ephemeral session with an in-memory cache only, so icons from
/// private windows never reach a disk cache.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()
    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> { [session] in
            guard Sanitize.isFetchableFavicon(url),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 0 < 400, data.count < 512_000 else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct FaviconView: View {
    let url: URL?
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
        .task(id: url) { image = nil; if let url { image = await FaviconLoader.shared.image(for: url) } }
    }
}
