import UniformTypeIdentifiers
import WebKit

/// Serves the built Svelte chrome (ui/dist) from `arc-ui://app/...`.
/// A custom scheme gives ES modules a real origin, which file:// URLs do not.
public final class UISchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "arc-ui"
    public static let entryURL = URL(string: "arc-ui://app/index.html")!

    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Maps a request URL to a file strictly inside `root` (no traversal).
    public func fileURL(for url: URL) -> URL? {
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let candidate = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let data: Data
        let mime: String
        if let file = fileURL(for: url), let contents = try? Data(contentsOf: file) {
            data = contents
            mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                ?? (file.pathExtension == "js" || file.pathExtension == "mjs" ? "text/javascript" : "application/octet-stream")
        } else if url.path == "/index.html" || url.path == "/" {
            data = Data(Self.missingBuildPage(root: root).utf8)
            mime = "text/html"
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(response)
            task.didReceive(Data())
            task.didFinish()
            return
        }
        let headers = [
            "Content-Type": mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
            "Content-Security-Policy": "default-src 'self' arc-ui:; img-src * data: blob:; style-src 'self' 'unsafe-inline' arc-ui:; script-src 'self' arc-ui:; connect-src 'self' arc-ui:",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func missingBuildPage(root: URL) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{color-scheme:light dark} body{font:13px -apple-system;padding:48px 16px;opacity:.8}
        code{display:block;margin-top:8px;font-size:11px}
        </style></head><body>
        <b>Sidebar UI not built.</b><p>Run in the repository root:</p><code>make ui</code>
        <p style="font-size:11px;opacity:.6">Looked in \(root.path)</p>
        </body></html>
        """
    }
}
