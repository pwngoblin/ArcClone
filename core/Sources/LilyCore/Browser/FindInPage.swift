import SwiftUI
import WebKit

/// Find in page (Edit → Find: ⌘F, ⌘G, ⇧⌘G) for the active tab: a bar above the page, WebKit's
/// own search (`WKWebView.find`, which selects and scrolls to each match, in every frame), and a
/// match count from `injections/modules/find-count.js`. While the bar is open, switching tabs
/// searches the new page.
@MainActor @Observable
final class FindModel {
    private(set) var isVisible = false
    var query = "" { didSet { if query != oldValue { search(backwards: false, fromTyping: true) } } }
    /// nil until something has been searched for.
    private(set) var found: Bool?
    /// Matches in the page's text (capped by find-count.js); nil when unknown.
    private(set) var matches: Int?
    /// Bumped to put the cursor back in the field (⌘F while the bar is already open).
    private(set) var focusRequest = 0
    @ObservationIgnored private weak var controller: BrowserWindowController?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    func show() {
        guard let controller else { return }
        if !isVisible {
            isVisible = true
            controller.contentController.setFindBar(NSHostingView(rootView: FindBarView(model: self)))
            if !query.isEmpty { search(backwards: false, fromTyping: false) }
        }
        focusRequest += 1
    }

    func hide() {
        guard isVisible else { return }
        task?.cancel()
        isVisible = false
        found = nil
        matches = nil
        controller?.contentController.setFindBar(nil)
        controller?.focusActivePage()
    }

    func next() { search(backwards: false, fromTyping: false) }
    func previous() { search(backwards: true, fromTyping: false) }

    func activeTabChanged() {
        guard isVisible, !query.isEmpty else { return }
        search(backwards: false, fromTyping: false)
    }

    func canPerform(_ action: NSTextFinder.Action?) -> Bool {
        guard controller?.tabs.active != nil else { return false }
        switch action {
        case .showFindInterface?: return true
        case .hideFindInterface?: return isVisible
        case .nextMatch?, .previousMatch?: return !query.isEmpty
        default: return false
        }
    }

    func perform(_ action: NSTextFinder.Action?) {
        switch action {
        case .showFindInterface?: show()
        case .hideFindInterface?: hide()
        case .nextMatch?: if isVisible { next() } else { show(); next() }
        case .previousMatch?: if isVisible { previous() } else { show(); previous() }
        default: break
        }
    }

    /// Typing waits a moment so each keystroke doesn't search; only the latest query's result is shown.
    private func search(backwards: Bool, fromTyping: Bool) {
        task?.cancel()
        let query = query
        guard isVisible, let tab = controller?.tabs.active, !query.isEmpty else {
            found = nil
            matches = nil
            return
        }
        task = Task { [weak self] in
            if fromTyping {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            let result = try? await tab.webView.find(query, configuration: configuration)
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.found = result?.matchFound ?? false
            guard fromTyping || self.matches == nil else { return }
            let count = try? await tab.callInjection("find.count", ["query": .string(query)], timeout: 3)
            guard !Task.isCancelled, self.query == query else { return }
            self.matches = count?["count"]?.int
        }
    }
}

/// The bar above the page: field, match count, previous / next, Done.
struct FindBarView: View {
    static let height: CGFloat = 36
    @Bindable var model: FindModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on Page", text: $model.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.next() }
                .onKeyPress(.escape) { model.hide(); return .handled }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.previous()
                    return .handled
                }
            if let status {
                Text(status.text).font(.caption).foregroundStyle(status.missing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit().fixedSize()
            }
            Button { model.previous() } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)").disabled(model.found != true)
            Button { model.next() } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)").disabled(model.found != true)
            Button("Done") { model.hide() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
    }

    private var status: (text: String, missing: Bool)? {
        switch model.found {
        case false?: return ("Not found", true)
        case true?:
            guard let matches = model.matches, matches > 0 else { return nil }
            return (matches >= 1_000 ? "1,000+ matches" : matches == 1 ? "1 match" : "\(matches) matches", false)
        case nil: return nil
        }
    }
}
