import Foundation

/// IPC routes linking the chrome's assistant panel to the agent bridge, enriched with page context
/// gathered from the active tab's injections.
extension BrowserWindowController {
    func registerAgentHandlers() {
        let chromeOnly: Set<IPCSource.Kind> = [.chrome]

        router.on("agent.health", from: chromeOnly) { [weak self] _, _ in
            guard let self else { return .null }
            return try await self.agent.client.call("bridge.health", [:], timeout: 15)
        }

        router.on("agent.models", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            return try await self.agent.client.call("models.list", ["refresh": .bool(p["refresh"]?.bool ?? false)])
        }

        router.on("agent.restart", from: chromeOnly) { [weak self] _, _ in
            self?.agent.restart()
            return .null
        }

        router.on("agent.cancel", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            return try await self.agent.client.call("agent.cancel", ["requestId": .string(try p.requiredString("requestId"))])
        }

        // Free-form question, optionally grounded in the current page / video / selection.
        router.on("agent.ask", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            let prompt = try p.requiredString("prompt")
            var messages = p["history"]?.array ?? []
            messages.append(["role": "user", "content": .string(prompt)])
            let context = await self.gatherContext(includePage: p["includePage"]?.bool ?? true,
                                                   includeSelection: p["includeSelection"]?.bool ?? true)
            return try await self.startAgentTask("chat", requestID: p["requestId"]?.string, model: p["model"]?.string,
                                                 extra: ["messages": .array(messages), "includeHistory": .bool(p["includeHistory"]?.bool ?? false)],
                                                 context: context)
        }

        // Summarise whatever is in the active tab: a YouTube video via its transcript, else the page.
        router.on("agent.summarize", from: chromeOnly) { [weak self] _, p in
            guard let self, let tab = self.tabs.active else { throw IPCError.notFound("No active tab") }
            let preferVideo = (p["source"]?.string ?? "auto") != "page"
            if preferVideo, tab.youtubeVideoID != nil {
                let transcript = try await tab.callInjection("youtube.transcript", ["lang": JSONValue(p["lang"]?.string)], timeout: 30)
                return try await self.startAgentTask("summarize-video", requestID: p["requestId"]?.string, model: p["model"]?.string,
                                                     extra: [:], context: ["transcript": transcript, "page": ["url": JSONValue(tab.url?.absoluteString), "title": .string(tab.title)]])
            }
            let page = try await tab.callInjection("dom.extract", ["maxChars": 200000])
            return try await self.startAgentTask("summarize", requestID: p["requestId"]?.string, model: p["model"]?.string,
                                                 extra: [:], context: ["page": page])
        }

        router.on("agent.explainSelection", from: chromeOnly) { [weak self] _, p in
            guard let self, let tab = self.tabs.active else { throw IPCError.notFound("No active tab") }
            guard let selection = p["text"]?.string ?? tab.lastSelection, !selection.isEmpty else {
                throw IPCError.invalidParams("Nothing is selected")
            }
            let page = (try? await tab.callInjection("dom.extract", ["maxChars": 20000])) ?? .null
            return try await self.startAgentTask("explain-selection", requestID: p["requestId"]?.string, model: p["model"]?.string,
                                                 extra: [:], context: ["page": page, "selection": .string(selection)])
        }

        // Raw access for the UI's transcript viewer.
        router.on("youtube.transcript", from: chromeOnly) { [weak self] _, p in
            guard let tab = self?.tabs.active else { throw IPCError.notFound("No active tab") }
            guard tab.youtubeVideoID != nil else { throw IPCError("not_video", "The active tab is not a YouTube video") }
            return try await tab.callInjection("youtube.transcript", p, timeout: 30)
        }
    }

    /// Collects page text, transcript and selection from the active tab. Failures degrade to less context.
    func gatherContext(includePage: Bool, includeSelection: Bool) async -> [String: JSONValue] {
        guard let tab = tabs.active else { return [:] }
        var context: [String: JSONValue] = [:]
        if includePage, tab.url?.scheme == "http" || tab.url?.scheme == "https" {
            if tab.youtubeVideoID != nil, let transcript = try? await tab.callInjection("youtube.transcript", [:], timeout: 30) {
                context["transcript"] = transcript
            }
            do {
                context["page"] = try await tab.callInjection("dom.extract", ["maxChars": 120000])
            } catch {
                Log.agent.info("Page extraction failed: \(String(describing: error), privacy: .public)")
                context["page"] = ["url": JSONValue(tab.url?.absoluteString), "title": .string(tab.title), "text": ""]
            }
        }
        if includeSelection, let selection = tab.lastSelection { context["selection"] = .string(selection) }
        return context
    }

    func startAgentTask(_ task: String, requestID: String?, model: String?, extra: [String: JSONValue],
                        context: [String: JSONValue]) async throws -> JSONValue {
        // Track the id before the call: stream notifications can arrive before the reply resolves.
        let id = requestID ?? UUID().uuidString
        ownedRequests.insert(id)
        var params: [String: JSONValue] = ["task": .string(task), "requestId": .string(id)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let tabID = tabs.activeID { params["tabId"] = .string(tabID.uuidString) }
        params.merge(context) { _, new in new }
        params.merge(extra) { _, new in new }
        do {
            return try await agent.client.call("agent.run", .object(params))
        } catch {
            ownedRequests.remove(id)
            throw error
        }
    }

    func handleAgentNotification(_ method: String, _ params: JSONValue) {
        if method == "bridge.restarted" {
            for id in ownedRequests {
                chrome.events.send("agent.error", ["requestId": .string(id), "code": "bridge_restarted", "message": "The agent bridge restarted"])
            }
            ownedRequests.removeAll()
            return
        }
        guard method.hasPrefix("agent."), let id = params["requestId"]?.string, ownedRequests.contains(id) else { return }
        chrome.events.send(method, params)
        if method == "agent.done" || method == "agent.error" { ownedRequests.remove(id) }
    }
}
