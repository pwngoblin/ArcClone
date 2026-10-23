import Foundation

/// App-wide owner of the agent bridge process. Windows subscribe for the requests they started.
@MainActor
public final class AgentService {
    public let client: AgentBridgeClient

    public init(paths: AppPaths) {
        var env: [String: String] = [:]
        let defaults = UserDefaults.standard
        if let host = defaults.string(forKey: "OllamaHost"), !host.isEmpty { env["OLLAMA_HOST"] = host }
        if let model = defaults.string(forKey: "AgentModel"), !model.isEmpty { env["ARC_AGENT_MODEL"] = model }
        client = AgentBridgeClient(paths: paths, environment: env)
    }

    public func start() {
        client.start()
    }

    public func restart() {
        client.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [client] in
            MainActor.assumeIsolated { client.start() }
        }
    }

    public func shutdown() {
        client.stop()
    }

    /// Forwards a local browser event so the agent keeps per-tab context.
    public func ingest(tabID: UUID, type: String, payload: JSONValue) {
        guard case .ready = client.status else { return }
        Task {
            _ = try? await client.call("events.ingest", ["tabId": .string(tabID.uuidString), "type": .string(type), "payload": payload], timeout: 5)
        }
    }
}
