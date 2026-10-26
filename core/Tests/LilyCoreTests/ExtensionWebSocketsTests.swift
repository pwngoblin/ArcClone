import Foundation
import Network
import Testing
import WebKit
@testable import LilyCore

/// A local WebSocket server that answers text with "echo:" + text and binary with the same bytes,
/// and records the Origin each connection sent.
private final class EchoServer: @unchecked Sendable {
    private final class Headers: @unchecked Sendable {
        let lock = NSLock()
        var origins: [String] = []
    }

    let listener: NWListener
    private let headers = Headers()
    var origins: [String] { headers.lock.withLock { headers.origins } }

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(DispatchQueue(label: "echo.handshake")) { [headers] _, fields in
            if let origin = fields.first(where: { $0.name.lowercased() == "origin" })?.value { headers.lock.withLock { headers.origins.append(origin) } }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func receive() {
                connection.receiveMessage { data, context, _, error in
                    guard error == nil, let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
                    let reply = metadata.opcode == .text ? Data("echo:".utf8) + data : data
                    let out = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
                    connection.send(content: reply, contentContext: NWConnection.ContentContext(identifier: "echo", metadata: [out]), isComplete: true, completion: .idempotent)
                    receive()
                }
            }
            receive()
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: .global())
        for _ in 0..<100 { if let port = listener.port?.rawValue, port != 0 { return port }; try await Task.sleep(for: .milliseconds(20)) }
        throw URLError(.cannotConnectToHost)
    }
}

@available(macOS 15.4, *)
@MainActor private final class SocketLily: NSObject, WKWebExtensionControllerDelegate {
    let webSockets = ExtensionWebSockets()
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        guard port.applicationIdentifier == ExtensionWebSockets.applicationIdentifier else { throw URLError(.badURL) }
        try webSockets.connect(port, from: extensionContext)
    }
}

@Suite @MainActor struct ExtensionWebSocketsTests {
    /// A worker's WebSocket goes through Lily: it opens, carries text and binary both ways, and closes
    /// cleanly, as the real one would.
    @Test func workerWebSocketConnectsThroughLily() async throws {
        guard #available(macOS 15.4, *) else { return }
        let server = try EchoServer()
        defer { server.listener.cancel() }
        let port = try await server.start()
        let shim = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../injections/extension-worker-compat.js").standardizedFileURL)
        let original = try ExtensionPackage(files: [
            "manifest.json": Data(#"{"name": "W", "version": "1", "manifest_version": 3, "background": {"service_worker": "bg.js", "type": "module"}, "action": {"default_title": "W"}}"#.utf8),
            "bg.js": Data("""
            const ws = new WebSocket('ws://127.0.0.1:\(port)/notifier');
            ws.binaryType = 'arraybuffer';
            ws.onopen = () => ws.send('ping');
            ws.addEventListener('message', (e) => {
              if (e.data === 'echo:ping') ws.send(new Uint8Array([1, 2, 3]));
              else if (e.data instanceof ArrayBuffer) { chrome.action.setBadgeText({ text: WebSocket.name + ':' + new Uint8Array(e.data).join('') }); ws.close(1000, 'done'); }
            });
            ws.onclose = (e) => chrome.action.setTitle({ title: `closed ${e.code} ${e.wasClean} ${ws.readyState}` });
            """.utf8),
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExtensionCompat.apply(to: original, shim: shim).write(to: dir)

        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let lily = SocketLily()
        controller.delegate = lily
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: dir))
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try controller.load(context)
        defer { try? controller.unload(context) }
        try await context.loadBackgroundContent()
        let action = context.action(for: nil)
        for _ in 0..<100 where !(action?.label ?? "").hasPrefix("closed") { try await Task.sleep(for: .milliseconds(50)) }

        #expect(action?.badgeText == "LilyWebSocket:123")
        #expect(action?.label == "closed 1000 true 3")
        #expect(server.origins == [ExtensionWebSockets.origin(of: context.baseURL)].compactMap { $0 })
    }

    @Test func requestsAreBounded() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionWebSockets.socketURL("wss://b5n.1password.com/notifier?token=x") != nil)
        #expect(ExtensionWebSockets.socketURL("ws://127.0.0.1:8080/") != nil)
        #expect(ExtensionWebSockets.socketURL("https://example.com/") == nil)
        #expect(ExtensionWebSockets.socketURL("file:///etc/passwd") == nil)
        #expect(ExtensionWebSockets.socketURL("wss:///nohost") == nil)
        #expect(ExtensionWebSockets.socketURL("wss://example.com/#frag") == nil)
        #expect(ExtensionWebSockets.validProtocols(nil) == [])
        #expect(ExtensionWebSockets.validProtocols(["chat", "v2.json"]) == ["chat", "v2.json"])
        #expect(ExtensionWebSockets.validProtocols(["a b"]) == nil)
        #expect(ExtensionWebSockets.validProtocols(["x", "x"]) == nil)
        #expect((try? ExtensionWebSockets.decode(["action": "launch"])) == nil)
        #expect((try? ExtensionWebSockets.decode(["action": "send", "text": "hi"]))?.text == "hi")
    }
}
