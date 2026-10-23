import Foundation

/// The built-in assistant: resolves a model, condenses long inputs (map-reduce), streams the
/// answer from Ollama and reports progress as `AssistantEvent`s. Runs in-process: no helper
/// executables, no extra sandbox exceptions.
@MainActor
public final class Assistant {
    public typealias Listener = @MainActor (AssistantEvent) -> Void

    public private(set) var configuration: AssistantConfiguration
    public let context = AssistantContextStore()
    private var ollama: OllamaClient
    private let session: URLSession
    private var running: [String: Task<Void, Never>] = [:]
    private var modelCache: (at: Date, models: [OllamaModel])?
    private var listeners: [UUID: Listener] = [:]

    public init(configuration: AssistantConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.ollama = Self.client(for: configuration, session: session)
    }

    private static func client(for configuration: AssistantConfiguration, session: URLSession) -> OllamaClient {
        OllamaClient(baseURL: configuration.baseURL, keepAlive: configuration.keepAlive,
                     streamTimeout: configuration.requestTimeout, session: session)
    }

    /// Applies changed settings; requests in flight are cancelled.
    public func reconfigure(_ configuration: AssistantConfiguration) {
        cancelAll()
        self.configuration = configuration
        ollama = Self.client(for: configuration, session: session)
        modelCache = nil
    }

    @discardableResult
    public func addListener(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public func removeListener(_ id: UUID) { listeners[id] = nil }

    public var runningCount: Int { running.count }

    // MARK: Models

    public func models(refresh: Bool = false) async throws -> [OllamaModel] {
        if !refresh, let cache = modelCache, Date().timeIntervalSince(cache.at) < 30 { return cache.models }
        let models = try await ollama.listModels()
        modelCache = (Date(), models)
        return models
    }

    func resolveModel(_ requested: String?) async throws -> String {
        let names = try await models().map(\.name)
        if let wanted = requested?.nilIfEmpty ?? configuration.defaultModel {
            if let match = names.first(where: { $0 == wanted || $0 == "\(wanted):latest" || $0.split(separator: ":").first.map(String.init) == wanted }) {
                return match
            }
            throw IPCError.noModel("Model '\(wanted)' is not installed. Run: ollama pull \(wanted)")
        }
        guard !names.isEmpty else { throw IPCError.noModel("No Ollama models are installed. Run: ollama pull llama3.2") }
        // Prefer chat-capable general models over embedding-only ones.
        return names.first { $0.range(of: "embed|bge|minilm|nomic", options: [.regularExpression, .caseInsensitive]) == nil } ?? names[0]
    }

    public func health() async -> JSONValue {
        var ollamaStatus: [String: JSONValue] = ["baseUrl": .string(configuration.baseURL.absoluteString)]
        do {
            async let version = ollama.version()
            async let models = models(refresh: true)
            let (v, m) = try await (version, models)
            ollamaStatus["reachable"] = true
            ollamaStatus["version"] = .string(v)
            ollamaStatus["modelCount"] = JSONValue(m.count)
        } catch {
            ollamaStatus["reachable"] = false
            ollamaStatus["error"] = .string((error as? IPCError)?.message ?? error.localizedDescription)
        }
        return ["assistant": ["running": JSONValue(running.count)], "ollama": .object(ollamaStatus),
                "defaultModel": JSONValue(configuration.defaultModel), "context": context.stats]
    }

    // MARK: Requests

    /// Validates and starts a request; progress arrives through listeners.
    public func start(_ request: AssistantRequest) async throws -> (requestID: String, model: String) {
        switch request.task {
        case .summarizeVideo where request.transcript?.text?.isEmpty ?? true:
            throw IPCError.invalidParams("summarize-video requires a transcript")
        case .explainSelection where (request.selection ?? context.selection(for: request.tabID))?.isEmpty ?? true:
            throw IPCError.invalidParams("explain-selection requires a selection")
        case .chat where !request.messages.contains { $0.role == .user }:
            throw IPCError.invalidParams("chat requires at least one user message")
        default:
            break
        }
        guard running[request.requestID] == nil else { throw IPCError.invalidParams("Request \(request.requestID) already running") }
        let model = try await resolveModel(request.model)
        let id = request.requestID
        running[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let (content, stats) = try await self.run(request, model: model)
                self.emit(.done(requestID: id, content: content, stats: stats, model: model, task: request.task))
            } catch {
                let failure = Task.isCancelled ? IPCError.cancelled : (error as? IPCError) ?? .internal(error.localizedDescription)
                if failure != .cancelled { Log.agent.error("Task \(request.task.rawValue, privacy: .public) failed: \(failure.message, privacy: .public)") }
                self.emit(.failed(requestID: id, error: failure))
            }
            self.running[id] = nil
        }
        return (id, model)
    }

    @discardableResult
    public func cancel(_ requestID: String) -> Bool {
        guard let task = running[requestID] else { return false }
        task.cancel()
        return true
    }

    public func cancelAll() { running.values.forEach { $0.cancel() } }

    private func emit(_ event: AssistantEvent) { listeners.values.forEach { $0(event) } }

    private func run(_ request: AssistantRequest, model: String) async throws -> (String, ChatStats?) {
        let id = request.requestID
        let max = configuration.maxContextChars
        let options: [String: JSONValue] = ["num_ctx": JSONValue(configuration.numCtx)]

        var page = request.page
        var transcript = request.transcript
        if let text = page?.text, text.count > max {
            page?.text = try await condense(text, kind: "page", model: model, options: options, requestID: id)
            page?.truncated = false
        }
        if let text = transcript?.text, text.count > max {
            transcript?.text = try await condense(text, kind: "transcript", model: model, options: options, requestID: id)
        }
        let selection = request.selection ?? (request.task == .explainSelection ? context.selection(for: request.tabID) : nil)
        let messages = try Prompts.messages(task: request.task, conversation: request.messages, page: page, transcript: transcript,
                                            selection: selection, history: request.includeHistory ? context.recentHistory() : [],
                                            maxChars: max)

        emit(.generating(requestID: id, model: model))
        let result = try await ollama.chat(model: model, messages: messages, options: options) { [weak self] delta in
            self?.emit(.delta(requestID: id, text: delta))
        }
        return (result.content, result.stats)
    }

    private func condense(_ text: String, kind: String, model: String, options: [String: JSONValue], requestID: String) async throws -> String {
        let chunks = Prompts.chunk(text, size: configuration.chunkChars)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw IPCError.cancelled }
            emit(.reading(requestID: requestID, kind: kind, part: index + 1, of: chunks.count))
            let excerpt = "<excerpt part=\"\(index + 1)/\(chunks.count)\" kind=\"\(kind)\">\n\(chunk)\n</excerpt>\n\n\(Prompts.chunkNotes)"
            let result = try await ollama.chat(model: model, messages: [ChatMessage(.system, Prompts.condenseSystem), ChatMessage(.user, excerpt)],
                                               options: options)
            notes.append("Part \(index + 1)/\(chunks.count):\n\(result.content.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return "[Condensed notes from a long \(kind)]\n\n\(notes.joined(separator: "\n\n"))"
    }
}
