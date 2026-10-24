import Foundation

/// Adding an extension straight from the Chrome Web Store: a store link or 32-letter ID becomes
/// Google's public CRX download, fetched without cookies or cache, capped in size, and verified
/// (`CRX3`) before it's unpacked, audited and pinned like any other extension.
enum ChromeWebStore {
    /// The Chrome version reported to the update service, which answers "no update" for any
    /// extension whose `minimum_chrome_version` is newer (1Password needs 137+). Derived from the
    /// date so it never goes stale: Chrome 120 shipped on 5 Dec 2023 and a new major version
    /// follows every four weeks. Holiday gaps make this run a version or two ahead, which the
    /// service accepts; running behind is what hides extensions.
    static func productVersion(on date: Date = Date()) -> String {
        let chrome120 = Date(timeIntervalSince1970: 1_701_734_400) // 2023-12-05 UTC
        let releases = max(0, Int(date.timeIntervalSince(chrome120) / (28 * 86_400)))
        return "\(120 + releases).0"
    }
    private static let storeHosts: Set<String> = ["chromewebstore.google.com", "chrome.google.com"]
    /// Where the update service redirects downloads.
    private static let downloadHosts = ["google.com", "googleusercontent.com", "gvt1.com"]

    /// The extension ID in a store link (`chromewebstore.google.com/detail/<name>/<id>`, or the
    /// older `chrome.google.com/webstore/detail/…`) or a bare ID; nil for anything else.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(text.lowercased()) { return text.lowercased() }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), storeHosts.contains(host) else { return nil }
        let parts = url.pathComponents
        guard host == "chromewebstore.google.com" ? parts.dropFirst().first == "detail" : parts.starts(with: ["/", "webstore", "detail"]) else { return nil }
        return parts.last { isExtensionID($0) }
    }

    static func isExtensionID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "p")).contains($0) }
    }

    /// The update service's on-demand download, which redirects to the CRX3 file.
    static func downloadURL(for id: String) -> URL? {
        guard isExtensionID(id) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.percentEncodedQuery = "response=redirect&prodversion=\(productVersion())&acceptformat=crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc"
        return components?.url
    }

    /// Downloads the extension's CRX3 (at most `ExtensionPackage.maxTotalBytes`). Off the main
    /// actor; the caller verifies it.
    static func download(_ id: String, session: URLSession? = nil) async throws -> Data {
        guard let url = downloadURL(for: id) else { throw ExtensionPackage.Invalid(reason: "That isn't a Chrome Web Store extension ID.") }
        let session = session ?? URLSession(configuration: ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url, final.scheme == "https",
              let host = final.host?.lowercased(), downloadHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw ExtensionPackage.Invalid(reason: "The Chrome Web Store sent an unexpected response.")
        }
        switch http.statusCode {
        case 200: break
        case 204, 404: throw ExtensionPackage.Invalid(reason: "The Chrome Web Store has no download for that extension.")
        default: throw ExtensionPackage.Invalid(reason: "The Chrome Web Store download failed (HTTP \(http.statusCode)).")
        }
        let limit = ExtensionPackage.maxTotalBytes
        let tooLarge = ExtensionPackage.Invalid(reason: "The extension is too large.")
        guard http.expectedContentLength <= Int64(limit) else { throw tooLarge }
        var data = Data()
        data.reserveCapacity(http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 1 << 20)
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw tooLarge }
        }
        return data
    }

    /// No cookies, cache or stored credentials: the download carries nothing about the user.
    private static var ephemeral: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}
