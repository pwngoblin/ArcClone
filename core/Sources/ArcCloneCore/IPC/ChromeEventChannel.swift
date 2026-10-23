import WebKit

/// Native -> chrome UI event push. Events are queued until the UI reports ready,
/// then delivered in order through `window.__arcChrome.receive(json)`.
@MainActor
public final class ChromeEventChannel {
    private weak var webView: WKWebView?
    private var queue: [String] = []
    public private(set) var isReady = false
    private let maxQueued = 500

    public init() {}

    public func bind(_ webView: WKWebView) {
        self.webView = webView
        isReady = false
    }

    public func markReady() {
        isReady = true
        let pending = queue
        queue.removeAll()
        pending.forEach(deliver)
    }

    /// The UI page reloaded or crashed: buffer until it says ready again.
    public func reset() {
        isReady = false
    }

    public func send(_ type: String, _ payload: JSONValue = .null) {
        let event: JSONValue = ["type": .string(type), "payload": payload]
        let json = event.jsonString()
        guard isReady else {
            queue.append(json)
            if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
            return
        }
        deliver(json)
    }

    private func deliver(_ json: String) {
        guard let webView else { return }
        // Passing the JSON as an argument (not string interpolation) avoids any escaping issues.
        webView.callAsyncJavaScript("window.__arcChrome && window.__arcChrome.receive(event)",
                                    arguments: ["event": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Log.ipc.error("Chrome event delivery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
