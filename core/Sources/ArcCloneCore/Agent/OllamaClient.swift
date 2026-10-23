import Foundation

/// Minimal Ollama HTTP client (https://github.com/ollama/ollama/blob/main/docs/api.md) with
/// streaming chat. Cancelling the calling task cancels the HTTP request.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    public let keepAlive: String
    public let streamTimeout: TimeInterval
    private let session: URLSession

    public init(baseURL: URL, keepAlive: String = "10m", streamTimeout: TimeInterval = 300, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.keepAlive = keepAlive
        self.streamTimeout = streamTimeout
        self.session = session
    }

    public func version() async throws -> String {
        let data = try await get("/api/version")
        return try JSONValue.parse(data)["version"]?.string ?? "unknown"
    }

    public func listModels() async throws -> [OllamaModel] {
        let tags = try JSONValue.parse(try await get("/api/tags"))
        return (tags["models"]?.array ?? []).compactMap { m in
            guard let name = m["name"]?.string else { return nil }
            let details = m["details"]
            return OllamaModel(name: name, size: m["size"]?.int, modifiedAt: m["modified_at"]?.string,
                               family: details?["family"]?.string, parameterSize: details?["parameter_size"]?.string,
                               quantization: details?["quantization_level"]?.string)
        }
    }

    /// Streams a chat completion, calling `onDelta` for each content fragment.
    public func chat(model: String, messages: [ChatMessage], options: [String: JSONValue],
                     onDelta: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> (content: String, stats: ChatStats?) {
        let body: JSONValue = ["model": .string(model), "messages": try JSONValue.from(messages), "stream": true,
                               "keep_alive": .string(keepAlive), "options": .object(options)]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: streamTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.jsonData()

        var content = ""
        var stats: ChatStats?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw Self.httpError(path: "/api/chat", status: http.statusCode, body: data)
            }
            for try await line in bytes.lines where !line.isEmpty {
                let event = try JSONValue.parse(line)
                if let error = event["error"]?.string { throw IPCError.ollamaError("Ollama: \(error)") }
                if let piece = event["message"]?["content"]?.string, !piece.isEmpty {
                    content += piece
                    await onDelta(piece)
                }
                if event["done"]?.bool == true {
                    stats = ChatStats(model: event["model"]?.string,
                                      totalDurationMs: event["total_duration"]?.double.map { Int($0 / 1_000_000) },
                                      promptTokens: event["prompt_eval_count"]?.int,
                                      completionTokens: event["eval_count"]?.int,
                                      doneReason: event["done_reason"]?.string)
                }
            }
        } catch {
            throw mapTransportError(error)
        }
        if Task.isCancelled { throw IPCError.cancelled }
        return (content, stats)
    }

    private func get(_ path: String) async throws -> Data {
        let request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())), timeoutInterval: 10)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Self.httpError(path: path, status: http.statusCode, body: data)
            }
            return data
        } catch {
            throw mapTransportError(error)
        }
    }

    private static func httpError(path: String, status: Int, body: Data) -> IPCError {
        let detail = (try? JSONValue.parse(body))?["error"]?.string
        return .ollamaError("Ollama \(path) returned \(status)\(detail.map { ": \($0)" } ?? "")")
    }

    private func mapTransportError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return IPCError.cancelled }
        if error is IPCError { return error }
        if error is URLError { return IPCError.ollamaUnavailable("Cannot reach Ollama at \(baseURL.absoluteString): \(error.localizedDescription)") }
        return IPCError.ollamaError("Unexpected Ollama response: \(error.localizedDescription)")
    }
}
