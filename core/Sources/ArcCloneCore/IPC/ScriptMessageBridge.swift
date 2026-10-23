import WebKit

/// Adapts WebKit's reply-capable script message handler to `IPCRouter`.
/// WKUserContentController retains its handlers strongly, so the router is held weakly
/// and the bridge must be removed with `detach(from:)` when its owner goes away.
@MainActor
public final class ScriptMessageBridge: NSObject, WKScriptMessageHandlerWithReply {
    public let name: String
    public let contentWorld: WKContentWorld
    private weak var router: IPCRouter?
    private let resolveSource: @MainActor (WKScriptMessage) -> IPCSource?

    public init(name: String, contentWorld: WKContentWorld, router: IPCRouter,
                resolveSource: @escaping @MainActor (WKScriptMessage) -> IPCSource?) {
        self.name = name
        self.contentWorld = contentWorld
        self.router = router
        self.resolveSource = resolveSource
    }

    public func attach(to controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: name)
    }

    public func detach(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage,
                                      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let router, let source = resolveSource(message) else {
            replyHandler(IPCReply.failure(.unavailable("Receiver is gone")).jsonString(), nil)
            return
        }
        let body = message.body as? String
        Task { @MainActor in
            let reply = await router.dispatch(rawBody: body as Any, source: source)
            replyHandler(reply, nil)
        }
    }
}
