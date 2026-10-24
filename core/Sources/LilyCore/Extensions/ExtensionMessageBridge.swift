import Foundation
import WebKit

/// The message handler for one compatibility-mode extension (see `ExtensionScriptInjector`),
/// registered only in that extension's content world. Messages are JSON `{ "action", "payload" }`
/// decoded into fixed shapes with size limits; anything else is refused. Answers never contain
/// code, and nothing a page or extension sends is ever evaluated.
@MainActor
final class ExtensionMessageBridge: NSObject, WKScriptMessageHandlerWithReply {
    nonisolated static let name = "lilyExtension"
    nonisolated static let maxMessageBytes = 1024 * 1024
    nonisolated static let maxKeys = 512

    /// A decoded message from the shim.
    enum Request: Equatable {
        case storageGet(keys: [String]?)
        case storageSet([String: JSONValue])
        case storageRemove([String])
        case storageClear
        case contentCSS
        case sendMessage
        case nativeMessage(application: String?)
    }

    let extensionID: String
    let contentWorld: WKContentWorld
    private weak var injector: ExtensionScriptInjector?

    init(extensionID: String, contentWorld: WKContentWorld, injector: ExtensionScriptInjector) {
        self.extensionID = extensionID
        self.contentWorld = contentWorld
        self.injector = injector
    }

    func attach(to controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: Self.name)
    }

    func detach(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.name, contentWorld: contentWorld)
    }

    /// Validates the raw body against the message schema.
    nonisolated static func decode(_ body: Any) throws -> Request {
        guard let text = body as? String, text.utf8.count <= maxMessageBytes else { throw IPCError.malformed("Message must be a JSON string under 1 MB") }
        let message = try JSONValue.parse(text)
        guard let action = message["action"]?.string else { throw IPCError.malformed("Missing action") }
        let payload = message["payload"] ?? .null
        func keys(_ value: JSONValue?) throws -> [String]? {
            guard let value, value != .null else { return nil }
            guard let list = value.array?.compactMap(\.string), list.count == value.array?.count, list.count <= maxKeys,
                  list.allSatisfy({ $0.count <= 256 }) else { throw IPCError.invalidParams("keys must be up to \(maxKeys) short strings") }
            return list
        }
        switch action {
        case "storage.get": return .storageGet(keys: try keys(payload["keys"]))
        case "storage.set":
            guard let items = payload["items"]?.object, items.count <= maxKeys, items.keys.allSatisfy({ $0.count <= 256 }) else {
                throw IPCError.invalidParams("items must be an object")
            }
            return .storageSet(items)
        case "storage.remove": return .storageRemove(try keys(payload["keys"]) ?? [])
        case "storage.clear": return .storageClear
        case "content.css": return .contentCSS
        case "runtime.sendMessage": return .sendMessage
        case "runtime.sendNativeMessage", "runtime.connectNative":
            return .nativeMessage(application: payload["application"]?.string.map { String($0.prefix(100)) })
        default: throw IPCError.unknownType(String(action.prefix(64)))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        // Only this extension's own world, only on web pages.
        guard message.world == contentWorld, ScriptMessageBridge.acceptsMessages(fromScheme: message.frameInfo.securityOrigin.protocol) else {
            replyHandler(IPCReply.failure(.forbidden(Self.name)).jsonString(), nil)
            return
        }
        let request: Request
        do { request = try Self.decode(message.body) } catch {
            replyHandler(IPCReply.failure(error as? IPCError ?? .malformed("Invalid message")).jsonString(), nil)
            return
        }
        let frameURL = message.frameInfo.request.url
        Task { @MainActor in
            replyHandler(await self.handle(request, frameURL: frameURL).jsonString(), nil)
        }
    }

    private func handle(_ request: Request, frameURL: URL?) async -> IPCReply {
        guard let library = injector?.library else { return .failure(.unavailable("Extension unloaded")) }
        let storage = library.storage
        let id = extensionID
        do {
            switch request {
            case .storageGet(let keys):
                return .success(.object(await storage.get(id, keys: keys)))
            case .storageSet(let items):
                try await storage.set(id, items)
                return .success(.null)
            case .storageRemove(let keys):
                await storage.remove(id, keys: keys)
                return .success(.null)
            case .storageClear:
                await storage.clear(id)
                return .success(.null)
            case .contentCSS:
                return .success(["css": .array((injector?.css(for: id, url: frameURL) ?? []).map(JSONValue.string))])
            case .sendMessage:
                return .failure(IPCError("unsupported", "Messaging the extension's background needs macOS 15.4 or later in Lily."))
            case .nativeMessage(let application):
                let refusal = await NativeMessagingHostManager.shared.request(application: application, extensionName: library.displayName(id))
                return .failure(IPCError("unsupported", refusal.errorDescription ?? "Not supported"))
            }
        } catch {
            return .failure(IPCError("failed", Sanitize.errorMessage(error)))
        }
    }
}
