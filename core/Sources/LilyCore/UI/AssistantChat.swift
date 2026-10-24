import Foundation
import Observation

/// One window's assistant conversation. Gathers page context from the active tab's injections,
/// starts `Assistant` requests and folds their streamed events into `messages`.
@MainActor @Observable
public final class AssistantChat {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        enum Status { case pending, streaming, done, cancelled, failed }

        let id: String
        let role: Role
        var content: String
        var status: Status = .done
        var phase: String?
        var model: String?
        var error: String?
        /// Set for canned prompts (summaries, explanations); those aren't replayed as chat history.
        var isAction = false
    }

    var messages: [Message] = []
    var models: [OllamaModel] = []
    var health: String?
    var includePage = true

    var isBusy: Bool { messages.contains { $0.status == .pending || $0.status == .streaming } }

    @ObservationIgnored private let assistant: Assistant
    @ObservationIgnored private var listener: UUID?
    @ObservationIgnored weak var window: BrowserWindowController?

    init(assistant: Assistant) {
        self.assistant = assistant
        listener = assistant.addListener { [weak self] in self?.apply($0) }
    }

    func detach() {
        if let listener { assistant.removeListener(listener) }
        messages.filter { $0.status == .pending || $0.status == .streaming }.forEach { assistant.cancel($0.id) }
    }

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: Preferences.Key.agentModel) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Preferences.Key.agentModel) }
    }

    func refreshModels() async {
        do {
            models = try await assistant.models(refresh: true)
            health = models.isEmpty ? "No Ollama models found. In Terminal run “ollama pull llama3.2”." : nil
        } catch {
            models = []
            health = Sanitize.errorMessage(error)
        }
    }

    // MARK: Requests

    func ask(_ prompt: String) {
        let history = messages.filter { !$0.isAction && ($0.role == .user || $0.status == .done) }.suffix(12)
            .map { ChatMessage($0.role == .user ? .user : .assistant, $0.content) }
        messages.append(Message(id: UUID().uuidString, role: .user, content: prompt))
        start { [includePage] window in
            var request = AssistantRequest(task: .chat, messages: history + [ChatMessage(.user, prompt)])
            let context = await window.gatherContext(includePage: includePage, includeSelection: true)
            request.page = context.page
            request.transcript = context.transcript
            request.selection = context.selection
            return request
        }
    }

    func summarize() {
        let isVideo = window?.tabs.active?.youtubeVideoID != nil
        messages.append(Message(id: UUID().uuidString, role: .user, content: isVideo ? "Summarize this video" : "Summarize this page", isAction: true))
        start { window in
            guard let tab = window.tabs.active else { throw IPCError.notFound("No active tab") }
            if tab.youtubeVideoID != nil {
                var request = AssistantRequest(task: .summarizeVideo)
                request.transcript = try await tab.callInjection("youtube.transcript", [:], timeout: 30).decode(Transcript.self)
                request.page = PageContent(url: tab.url?.absoluteString, title: tab.title)
                return request
            }
            var request = AssistantRequest(task: .summarize)
            request.page = try await tab.callInjection("dom.extract", ["maxChars": 200000]).decode(PageContent.self)
            return request
        }
    }

    func explain(_ selection: String) {
        let preview = selection.count > 140 ? "\(selection.prefix(140))…" : selection
        messages.append(Message(id: UUID().uuidString, role: .user, content: "Explain: “\(preview)”", isAction: true))
        start { window in
            var request = AssistantRequest(task: .explainSelection, selection: selection)
            request.page = try? await window.tabs.active?.callInjection("dom.extract", ["maxChars": 20000]).decode(PageContent.self)
            return request
        }
    }

    func cancel(_ id: String) { assistant.cancel(id) }

    func clear() {
        messages.filter { $0.status == .pending || $0.status == .streaming }.forEach { assistant.cancel($0.id) }
        messages.removeAll()
    }

    /// Seeks the active YouTube video to a transcript timestamp the answer cited.
    func seek(to seconds: Double) {
        guard let tab = window?.tabs.active else { return }
        Task { _ = try? await tab.callInjection("youtube.seek", ["seconds": .number(seconds)]) }
    }

    private func start(_ build: @escaping @MainActor (BrowserWindowController) async throws -> AssistantRequest) {
        let id = UUID().uuidString
        messages.append(Message(id: id, role: .assistant, content: "", status: .pending))
        Task {
            do {
                guard let window else { throw IPCError.unavailable("Window closed") }
                var request = try await build(window)
                request.requestID = id
                request.tabID = window.tabs.activeID
                request.model = selectedModel.isEmpty ? nil : selectedModel
                if window.isPrivate { request.includeHistory = false }
                let started = try await assistant.start(request)
                update(id) { $0.model = started.model }
            } catch {
                update(id) {
                    $0.status = .failed
                    $0.error = Sanitize.errorMessage(error)
                }
            }
        }
    }

    private func apply(_ event: AssistantEvent) {
        let id = event.requestID
        switch event {
        case .generating(_, let model):
            update(id) { $0.phase = nil; $0.model = model }
        case .reading(_, _, let part, let of):
            update(id) { $0.phase = "Reading part \(part) of \(of)…" }
        case .delta(_, let text):
            update(id) { $0.status = .streaming; $0.phase = nil; $0.content += text }
        case .done(_, let content, _, let model, _):
            update(id) { $0.status = .done; $0.content = content; $0.model = model }
        case .failed(_, let error):
            update(id) {
                $0.status = error == .cancelled ? .cancelled : .failed
                $0.error = error.message
            }
        }
    }

    private func update(_ id: String, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}
