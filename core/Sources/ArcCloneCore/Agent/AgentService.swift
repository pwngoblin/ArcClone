import Foundation

/// App-wide owner of the agent bridge process. Windows subscribe for the requests they started.
@MainActor
public final class AgentService {
    public let client: AgentBridgeClient

    public init(paths: AppPaths) {
        client = AgentBridgeClient(paths: paths, environment: Self.environmentFromPreferences())
    }

    private static func environmentFromPreferences() -> [String: String] {
        var env: [String: String] = [:]
        // Development builds pass bridge settings through from the shell (`OLLAMA_HOST=… make run`).
        if !AppInfo.isPackaged {
            env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ARC_AGENT_") || $0.key == "OLLAMA_HOST" }
        }
        let defaults = UserDefaults.standard
        if let host = defaults.string(forKey: Preferences.Key.ollamaHost), !host.isEmpty { env["OLLAMA_HOST"] = host }
        if let model = defaults.string(forKey: Preferences.Key.agentModel), !model.isEmpty { env["ARC_AGENT_MODEL"] = model }
        return env
    }

    public func start() {
        client.start()
    }

    /// Also picks up changed assistant settings.
    public func restart() {
        client.stop()
        client.setEnvironment(Self.environmentFromPreferences())
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
