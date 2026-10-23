import Foundation

/// IPC routes linking the chrome's assistant panel to the in-process `Assistant`, enriched with
/// page context gathered from the active tab's injections.
extension BrowserWindowController {
    func registerAgentHandlers() {
        let chromeOnly: Set<IPCSource.Kind> = [.chrome]

        router.on("agent.health", from: chromeOnly) { [weak self] _, _ in
            guard let self else { return .null }
            return await self.assistant.health()
        }

        router.on("agent.models", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            let models = try await self.assistant.models(refresh: p["refresh"]?.bool ?? false)
            return ["models": try JSONValue.from(models)]
        }

        router.on("agent.restart", from: chromeOnly) { [weak self] _, _ in
            self?.assistant.reconfigure(.fromPreferences())
            return .null
        }

        router.on("agent.cancel", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            return ["cancelled": .bool(self.assistant.cancel(try p.requiredString("requestId")))]
        }

        // Free-form question, optionally grounded in the current page / video / selection.
        router.on("agent.ask", from: chromeOnly) { [weak self] _, p in
            guard let self else { return .null }
            var messages = (try? p["history"]?.decode([ChatMessage].self)) ?? []
            messages.append(ChatMessage(.user, try p.requiredString("prompt")))
            let context = await self.gatherContext(includePage: p["includePage"]?.bool ?? true,
                                                   includeSelection: p["includeSelection"]?.bool ?? true)
            var request = self.makeRequest(.chat, p)
            request.messages = messages
            request.page = context.page
            request.transcript = context.transcript
            request.selection = context.selection
            request.includeHistory = p["includeHistory"]?.bool ?? false
            return try await self.startAssistant(request)
        }

        // Summarise whatever is in the active tab: a YouTube video via its transcript, else the page.
        router.on("agent.summarize", from: chromeOnly) { [weak self] _, p in
            guard let self, let tab = self.tabs.active else { throw IPCError.notFound("No active tab") }
            if (p["source"]?.string ?? "auto") != "page", tab.youtubeVideoID != nil {
                var request = self.makeRequest(.summarizeVideo, p)
                request.transcript = try await tab.callInjection("youtube.transcript", ["lang": JSONValue(p["lang"]?.string)], timeout: 30)
                    .decode(Transcript.self)
                request.page = PageContent(url: tab.url?.absoluteString, title: tab.title)
                return try await self.startAssistant(request)
            }
            var request = self.makeRequest(.summarize, p)
            request.page = try await tab.callInjection("dom.extract", ["maxChars": 200000]).decode(PageContent.self)
            return try await self.startAssistant(request)
        }

        router.on("agent.explainSelection", from: chromeOnly) { [weak self] _, p in
            guard let self, let tab = self.tabs.active else { throw IPCError.notFound("No active tab") }
            guard let selection = p["text"]?.string ?? tab.lastSelection, !selection.isEmpty else {
                throw IPCError.invalidParams("Nothing is selected")
            }
            var request = self.makeRequest(.explainSelection, p)
            request.selection = selection
            request.page = try? await tab.callInjection("dom.extract", ["maxChars": 20000]).decode(PageContent.self)
            return try await self.startAssistant(request)
        }

        // Raw access for the UI's transcript viewer.
        router.on("youtube.transcript", from: chromeOnly) { [weak self] _, p in
            guard let tab = self?.tabs.active else { throw IPCError.notFound("No active tab") }
            guard tab.youtubeVideoID != nil else { throw IPCError("not_video", "The active tab is not a YouTube video") }
            return try await tab.callInjection("youtube.transcript", p, timeout: 30)
        }
    }

    /// Collects page text, transcript and selection from the active tab. Failures degrade to less context.
    func gatherContext(includePage: Bool, includeSelection: Bool) async -> (page: PageContent?, transcript: Transcript?, selection: String?) {
        guard let tab = tabs.active else { return (nil, nil, nil) }
        var page: PageContent?
        var transcript: Transcript?
        if includePage, tab.url?.scheme == "http" || tab.url?.scheme == "https" {
            if tab.youtubeVideoID != nil {
                transcript = try? await tab.callInjection("youtube.transcript", [:], timeout: 30).decode(Transcript.self)
            }
            do {
                page = try await tab.callInjection("dom.extract", ["maxChars": 120000]).decode(PageContent.self)
            } catch {
                Log.agent.info("Page extraction failed: \(String(describing: error), privacy: .public)")
                page = PageContent(url: tab.url?.absoluteString, title: tab.title, text: "")
            }
        }
        return (page, transcript, includeSelection ? tab.lastSelection : nil)
    }

    private func makeRequest(_ task: AssistantTask, _ p: JSONValue) -> AssistantRequest {
        AssistantRequest(task: task, requestID: p["requestId"]?.string ?? UUID().uuidString, tabID: tabs.activeID,
                         model: p["model"]?.string)
    }

    private func startAssistant(_ request: AssistantRequest) async throws -> JSONValue {
        // Track the id before starting: stream events can arrive before `start` returns.
        ownedRequests.insert(request.requestID)
        do {
            let started = try await assistant.start(request)
            return ["requestId": .string(started.requestID), "model": .string(started.model), "task": .string(request.task.rawValue)]
        } catch {
            ownedRequests.remove(request.requestID)
            throw error
        }
    }

    func handleAssistantEvent(_ event: AssistantEvent) {
        guard ownedRequests.contains(event.requestID) else { return }
        let (type, payload) = event.json
        chrome.events.send(type, payload)
        if event.isTerminal { ownedRequests.remove(event.requestID) }
    }
}
