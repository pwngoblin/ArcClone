import Foundation
import WebKit

/// WebSockets for extension backgrounds. In WebKit an extension's service worker runs on its web
/// process's main thread, and `new WebSocket("wss://…")` there waits for that same thread to set
/// the connection up: the background freezes for good. 1Password opens its sync connection right
/// after sign-in, so the sign-in never finished, and its popup and autofill stopped answering.
///
/// Lily's worker shim (`injections/extension-worker-compat.js`) replaces `WebSocket` in a
/// service worker with a stand-in that connects through Lily instead: one native-messaging port
/// per socket, on a name Lily answers itself (`applicationIdentifier`). Requests are decoded into
/// a fixed schema with limits, only `ws:`/`wss:` URLs are opened, the connection sends the
/// extension's origin as a WebSocket from its background would, and it carries no cookies. A
/// socket closes with its port: when the background unloads, or the extension is turned off.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWebSockets: NSObject, URLSessionWebSocketDelegate {
    nonisolated static let applicationIdentifier = "dev.lily.websocket"
    nonisolated static let maxMessageBytes = 1 << 20
    nonisolated static let maxSocketsPerExtension = 16

    struct Request: Decodable, Equatable {
        enum Action: String, Decodable { case open, send, close }
        let action: Action
        var url: String?
        var protocols: [String]?
        var text: String?
        /// Base64, for binary messages.
        var binary: String?
        var code: Int?
        var reason: String?
    }

    struct Refused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    nonisolated static func decode(_ message: Any) throws -> Request {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= maxMessageBytes * 4 / 3 + 1_024,
              let request = try? JSONDecoder().decode(Request.self, from: data) else { throw Refused(reason: "Invalid WebSocket request") }
        return request
    }

    /// The URL a socket may open: `ws:` or `wss:` with a host, as `new WebSocket` accepts.
    nonisolated static func socketURL(_ string: String?) -> URL? {
        guard let string, string.utf8.count <= 8 * 1_024, let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              components.host?.isEmpty == false, components.fragment == nil else { return nil }
        return components.url
    }

    /// Subprotocol names are HTTP tokens.
    nonisolated static func validProtocols(_ protocols: [String]?) -> [String]? {
        let list = protocols ?? []
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard list.count <= 16, Set(list).count == list.count,
              list.allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0.unicodeScalars.allSatisfy(token.contains) }) else { return nil }
        return list
    }

    private final class Socket {
        let ext: String
        let port: WKWebExtension.MessagePort
        var task: URLSessionWebSocketTask?
        init(ext: String, port: WKWebExtension.MessagePort) { self.ext = ext; self.port = port }
    }

    /// Keyed by the port, and by the task once it's opened.
    private var sockets: [ObjectIdentifier: Socket] = [:]
    private var tasks: [Int: Socket] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        // Callbacks arrive on the main queue, in order, so events reach the extension in order.
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// The shim opened a port for a new socket; it sends `open` once told it's ready.
    func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) throws {
        let ext = context.uniqueIdentifier
        guard sockets.values.filter({ $0.ext == ext }).count < Self.maxSocketsPerExtension else {
            throw Refused(reason: "Too many WebSockets open")
        }
        let socket = Socket(ext: ext, port: port)
        let key = ObjectIdentifier(port)
        sockets[key] = socket
        let origin = Self.origin(of: context.baseURL)
        port.messageHandler = { [weak self] message, _ in
            MainActor.assumeIsolated { self?.received(message, on: key, origin: origin) }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.close(key, code: .goingAway) }
        }
        // The port carries messages only once this call has returned, so the shim waits for this
        // before it asks to open.
        Task { @MainActor [weak port] in port?.sendMessage(["type": "ready"], completionHandler: nil) }
    }

    /// The extension was removed or turned off: its sockets close.
    func removeAll(for ext: String) {
        for (key, socket) in sockets where socket.ext == ext {
            close(key, code: .goingAway)
            socket.port.disconnect()
        }
    }

    private func received(_ message: Any?, on key: ObjectIdentifier, origin: String?) {
        guard let socket = sockets[key] else { return }
        guard let message, let request = try? Self.decode(message) else { return fail(key) }
        switch request.action {
        case .open:
            guard socket.task == nil, let url = Self.socketURL(request.url), let protocols = Self.validProtocols(request.protocols) else { return fail(key) }
            var urlRequest = URLRequest(url: url)
            if let origin { urlRequest.setValue(origin, forHTTPHeaderField: "Origin") }
            if !protocols.isEmpty { urlRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
            let task = session.webSocketTask(with: urlRequest)
            task.maximumMessageSize = Self.maxMessageBytes
            socket.task = task
            tasks[task.taskIdentifier] = socket
            task.resume()
            receive(on: task)
        case .send:
            guard let task = socket.task else { return fail(key) }
            let outgoing: URLSessionWebSocketTask.Message
            if let text = request.text, text.utf8.count <= Self.maxMessageBytes {
                outgoing = .string(text)
            } else if let binary = request.binary.flatMap({ Data(base64Encoded: $0) }), binary.count <= Self.maxMessageBytes {
                outgoing = .data(binary)
            } else {
                return fail(key)
            }
            task.send(outgoing) { _ in }
        case .close:
            let code = request.code.flatMap { URLSessionWebSocketTask.CloseCode(rawValue: $0) } ?? .normalClosure
            let reason = request.reason.map { Data($0.prefix(123).utf8) }
            socket.task?.cancel(with: code, reason: reason)
            if socket.task == nil { finish(key, ["type": "close", "code": 1000, "reason": "", "wasClean": true]) }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, let socket = self.tasks[task.taskIdentifier], socket.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    socket.port.sendMessage(["type": "message", "text": text], completionHandler: nil)
                case .success(.data(let data)):
                    socket.port.sendMessage(["type": "message", "binary": data.base64EncodedString()], completionHandler: nil)
                case .success:
                    break
                case .failure:
                    // The close or the failure is reported by the delegate.
                    return
                }
                self.receive(on: task)
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let id = webSocketTask.taskIdentifier
        MainActor.assumeIsolated {
            tasks[id]?.port.sendMessage(["type": "open", "protocol": `protocol` ?? ""], completionHandler: nil)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let id = webSocketTask.taskIdentifier
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        MainActor.assumeIsolated {
            guard let socket = tasks[id] else { return }
            finish(ObjectIdentifier(socket.port), ["type": "close", "code": closeCode.rawValue, "reason": text, "wasClean": true])
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        // A close the server or the extension started can end here without `didCloseWith`.
        let socketTask = task as? URLSessionWebSocketTask
        let code = error == nil ? socketTask?.closeCode ?? .invalid : .invalid
        let reason = socketTask?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        MainActor.assumeIsolated {
            guard let socket = tasks[id] else { return }
            let key = ObjectIdentifier(socket.port)
            if code == .invalid { fail(key) } else { finish(key, ["type": "close", "code": code.rawValue, "reason": reason, "wasClean": true]) }
        }
    }

    // MARK: Helpers

    /// A failed connection, as WebKit reports one: an error, then an unclean close.
    private func fail(_ key: ObjectIdentifier) {
        sockets[key]?.port.sendMessage(["type": "error"], completionHandler: nil)
        finish(key, ["type": "close", "code": 1006, "reason": "", "wasClean": false])
    }

    /// Reports the close, then ends the socket and its port.
    private func finish(_ key: ObjectIdentifier, _ event: [String: Any]) {
        guard let socket = sockets[key] else { return }
        close(key, code: .normalClosure)
        socket.port.sendMessage(event) { [weak port = socket.port] _ in port?.disconnect() }
    }

    private func close(_ key: ObjectIdentifier, code: URLSessionWebSocketTask.CloseCode) {
        guard let socket = sockets.removeValue(forKey: key) else { return }
        if let task = socket.task {
            tasks[task.taskIdentifier] = nil
            if task.state == .running { task.cancel(with: code, reason: nil) }
        }
    }

    nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host)"
    }
}
