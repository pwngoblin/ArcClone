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

    /// The tab moved to another window (Little Lily → Open in Lily): its pages' messages now reach
    /// that window's routes. The handler, its content world and its checks stay as they are.
    public func rebind(router: IPCRouter) { self.router = router }

    public func attach(to controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: name)
    }

    /// Web pages and local files the user opened; never `webkit-extension:` and similar.
    nonisolated static func acceptsMessages(fromScheme scheme: String) -> Bool {
        ["https", "http", "file"].contains(scheme.lowercased())
    }

    public func detach(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage,
                                      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        // Only our injected scripts, and only on web pages: not another content world (extension
        // content scripts have their own), and not extension pages opened in a tab.
        guard message.world == contentWorld, Self.acceptsMessages(fromScheme: message.frameInfo.securityOrigin.protocol) else {
            replyHandler(IPCReply.failure(.forbidden(name)).jsonString(), nil)
            return
        }
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
