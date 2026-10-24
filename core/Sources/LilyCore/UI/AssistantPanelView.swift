import SwiftUI

/// The assistant chat in the sidebar.
struct AssistantPanelView: View {
    @Bindable var chat: AssistantChat
    let window: WindowModel
    @State private var prompt = ""
    @FocusState private var composerFocused: Bool

    private var isVideo: Bool { window.activeTab?.isYouTubeVideo == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let health = chat.health {
                Text(health).font(.caption).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty { emptyState }
                        ForEach(chat.messages) { MessageBubble(message: $0, chat: chat, window: window).id($0.id) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .onChange(of: chat.messages.last?.content) { _, _ in
                    if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
        .task { await chat.refreshModels() }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("Assistant", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
            Spacer()
            Menu {
                Picker("Model", selection: Binding(get: { chat.selectedModel }, set: { chat.selectedModel = $0 })) {
                    Text("Automatic").tag("")
                    ForEach(chat.models, id: \.name) { Text($0.name).tag($0.name) }
                }
                Button("Refresh Models") { Task { await chat.refreshModels() } }
            } label: {
                Text(chat.selectedModel.isEmpty ? "Auto" : chat.selectedModel).font(.caption).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            NavButton(symbol: "trash", help: "Clear Conversation", enabled: !chat.messages.isEmpty) { chat.clear() }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about \(isVideo ? "this video" : "this page"), or anything else. Everything runs locally through Ollama.")
                .font(.callout).foregroundStyle(.secondary)
            actionChips
        }
        .padding(.top, 8)
    }

    private var actionChips: some View {
        HStack(spacing: 6) {
            Button { chat.summarize() } label: { Label(isVideo ? "Summarize video" : "Summarize page", systemImage: "text.alignleft") }
                .disabled(window.activeTab == nil || chat.isBusy)
            if let selection = window.selection {
                Button { chat.explain(selection) } label: { Label("Explain selection", systemImage: "quote.bubble") }
                    .disabled(chat.isBusy)
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.messages.isEmpty { actionChips }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                if let running = chat.messages.last(where: { $0.status == .pending || $0.status == .streaming }) {
                    Button { chat.cancel(running.id) } label: { Image(systemName: "stop.circle.fill").font(.title3) }
                        .buttonStyle(.plain).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                        .buttonStyle(.plain).disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Toggle("Use this page", isOn: $chat.includePage).toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.top, 6)
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isBusy else { return }
        prompt = ""
        chat.ask(text)
    }
}

private struct MessageBubble: View {
    let message: AssistantChat.Message
    let chat: AssistantChat
    let window: WindowModel

    var body: some View {
        switch message.role {
        case .user:
            Text(message.content)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty && message.status == .pending || message.phase != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message.phase ?? "Thinking…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.content.isEmpty {
                    Text(MarkdownRenderer.attributed(message.content))
                        .font(.callout)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == MarkdownRenderer.seekScheme, let seconds = Double(url.host ?? "") {
                                chat.seek(to: seconds)
                            } else if url.scheme == "https" || url.scheme == "http" {
                                window.controller?.open(url, newTab: true)
                            }
                            return .handled
                        })
                }
                if let error = message.error, message.status == .failed || message.status == .cancelled {
                    Text(message.status == .cancelled ? "Stopped" : error).font(.caption).foregroundStyle(message.status == .cancelled ? .secondary : Color.red)
                }
                if message.status == .done {
                    HStack(spacing: 8) {
                        if let model = message.model { Text(model).font(.caption2).foregroundStyle(.tertiary) }
                        Button {
                            Clipboard.copy(message.content, sensitive: window.isPrivate)
                            window.showToast("Copied")
                        } label: { Image(systemName: "doc.on.doc").font(.caption) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Copy")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Markdown for assistant replies via Foundation's parser (no HTML involved), with [mm:ss]
/// transcript timestamps turned into links that seek the active video.
enum MarkdownRenderer {
    static let seekScheme = "lily-seek"

    static func attributed(_ text: String) -> AttributedString {
        let linked = text.replacing(/\[((?:\d{1,2}:)?\d{1,2}:\d{2})\](?!\()/) { match in
            let parts = match.output.1.split(separator: ":").compactMap { Double($0) }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            return "[\(match.output.1)](\(seekScheme)://\(Int(seconds)))"
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(text)
    }
}
