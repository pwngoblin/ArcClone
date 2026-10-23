import Foundation

/// JSON-RPC 2.0 client for the agent-bridge Node process (see agent-bridge/src/rpc.js).
@MainActor
public final class AgentBridgeClient {
    public typealias NotificationHandler = @MainActor (_ method: String, _ params: JSONValue) -> Void

    public enum Status: Equatable, Sendable {
        case unavailable(String)
        case starting
        case ready
        case restarting
        case failed(String)

        public var json: JSONValue {
            switch self {
            case .unavailable(let m): return ["state": "unavailable", "message": .string(m)]
            case .starting: return ["state": "starting"]
            case .ready: return ["state": "ready"]
            case .restarting: return ["state": "restarting"]
            case .failed(let m): return ["state": "failed", "message": .string(m)]
            }
        }
    }

    private var process: ManagedProcess?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var listeners: [UUID: NotificationHandler] = [:]
    private var statusListeners: [UUID: @MainActor (Status) -> Void] = [:]
    public var defaultTimeout: TimeInterval = 30

    public private(set) var status: Status {
        didSet { if oldValue != status { statusListeners.values.forEach { $0(status) } } }
    }

    public init(paths: AppPaths, environment: [String: String] = [:]) {
        guard FileManager.default.fileExists(atPath: paths.agentBridgeMain.path) else {
            status = .unavailable("agent-bridge not found at \(paths.agentBridgeMain.path)")
            return
        }
        guard let node = Executables.find("node") else {
            status = .unavailable("Node.js not found. Install it (brew install node) or set ARCCLONE_NODE.")
            return
        }
        status = .starting
        let spec = ManagedProcess.Spec(executable: node,
                                       arguments: [paths.agentBridgeMain.path],
                                       environment: environment,
                                       workingDirectory: paths.agentBridgeMain.deletingLastPathComponent().deletingLastPathComponent())
        let proc = ManagedProcess(name: "agent-bridge", spec: spec)
        proc.onLine = { [weak self] line in self?.handle(line: line) }
        proc.onStateChange = { [weak self] state in self?.processStateChanged(state) }
        process = proc
    }

    public func start() { process?.start() }

    /// Takes effect on the next start.
    public func setEnvironment(_ environment: [String: String]) {
        process?.spec.environment = environment
    }

    public func stop() {
        failAll(IPCError.unavailable("Agent bridge stopped"))
        process?.stop()
    }

    @discardableResult
    public func addListener(_ handler: @escaping NotificationHandler) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    @discardableResult
    public func addStatusListener(_ handler: @escaping @MainActor (Status) -> Void) -> UUID {
        let id = UUID()
        statusListeners[id] = handler
        return id
    }

    public func removeListener(_ id: UUID) {
        listeners[id] = nil
        statusListeners[id] = nil
    }

    /// Sends a request and awaits its result. Throws `IPCError` on RPC errors or timeout.
    public func call(_ method: String, _ params: JSONValue = [:], timeout: TimeInterval? = nil) async throws -> JSONValue {
        guard let process else {
            if case .unavailable(let m) = status { throw IPCError.unavailable(m) }
            throw IPCError.unavailable("Agent bridge unavailable")
        }
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": JSONValue(id), "method": .string(method), "params": params]
        let limit = timeout ?? defaultTimeout

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try process.send(line: message.jsonString())
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let c = self.pending.removeValue(forKey: id) else { return }
                    c.resume(throwing: IPCError("timeout", "\(method) timed out after \(Int(limit))s"))
                }
            }
        }
    }

    private func handle(line: String) {
        guard let message = try? JSONValue.parse(line) else {
            Log.agent.error("Unparseable line from agent bridge: \(line.prefix(200), privacy: .public)")
            return
        }
        if let id = message["id"]?.int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"], !error.isNull {
                continuation.resume(throwing: Self.mapError(error))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        guard let method = message["method"]?.string else { return }
        let params = message["params"] ?? .null
        if method == "bridge.ready" { status = .ready }
        listeners.values.forEach { $0(method, params) }
    }

    static func mapError(_ error: JSONValue) -> IPCError {
        let code = error["code"]?.int ?? -32603
        let message = error["message"]?.string ?? "Agent error"
        switch code {
        case -32001: return IPCError("ollama_unavailable", message)
        case -32002: return IPCError("no_model", message)
        case -32003: return IPCError("cancelled", message)
        case -32004: return IPCError("ollama_error", message)
        case -32601: return IPCError("unknown_method", message)
        case -32602: return IPCError.invalidParams(message)
        default: return IPCError.internal(message)
        }
    }

    private func processStateChanged(_ state: ManagedProcess.State) {
        switch state {
        case .running: status = .starting // becomes .ready on the bridge.ready notification
        case .restarting:
            failAll(IPCError.unavailable("Agent bridge restarted"))
            status = .restarting
        case .failed(let reason):
            failAll(IPCError.unavailable(reason))
            status = .failed(reason)
        case .stopped:
            failAll(IPCError.unavailable("Agent bridge stopped"))
            status = .unavailable("stopped")
        }
        if case .restarting = state {
            // In-flight streams died with the process; let listeners close them out.
            listeners.values.forEach { $0("bridge.restarted", .null) }
        }
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }
}
