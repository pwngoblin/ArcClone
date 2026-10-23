import SwiftUI

/// State for the centered command bar (⌘T / ⌘L).
@MainActor @Observable
final class CommandBarModel: Identifiable {
    enum Suggestion: Identifiable, Equatable {
        case open(URL)
        case search(String, engine: String)
        case tab(id: UUID, title: String, url: URL?)
        case history(title: String, url: URL)

        var id: String {
            switch self {
            case .open(let url): return "open:\(url.absoluteString)"
            case .search(let q, _): return "search:\(q)"
            case .tab(let id, _, _): return "tab:\(id.uuidString)"
            case .history(_, let url): return "history:\(url.absoluteString)"
            }
        }
    }

    let id = UUID()
    let newTab: Bool
    var query: String { didSet { selection = 0 } }
    var selection = 0
    @ObservationIgnored private weak var window: WindowModel?

    init(newTab: Bool, query: String, window: WindowModel) {
        self.newTab = newTab
        self.query = query
        self.window = window
    }

    var suggestions: [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let window else { return [] }
        var out: [Suggestion] = []
        let resolver = Preferences.urlResolver
        if let url = resolver.resolve(q), url.absoluteString != resolver.searchURL(for: q)?.absoluteString {
            out.append(.open(url))
        }
        out.append(.search(q, engine: Preferences.searchEngine.displayName))
        let needle = q.lowercased()
        let tabs = window.tabs.filter { $0.id != window.activeID || newTab }
            .filter { $0.title.lowercased().contains(needle) || ($0.url?.absoluteString.lowercased().contains(needle) ?? false) }
        out += tabs.prefix(4).map { .tab(id: $0.id, title: $0.title, url: $0.url) }
        if let history = window.controller?.history {
            let open = Set(out.compactMap { if case .tab(_, _, let url) = $0 { url } else { nil } })
            for visit in history.search(q, limit: 12) where !open.contains(visit.url) {
                out.append(.history(title: visit.title.isEmpty ? visit.url.absoluteString : visit.title, url: visit.url))
                if out.count >= 9 { break }
            }
        }
        return out
    }

    func moveSelection(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func commit(_ suggestion: Suggestion? = nil) {
        guard let window, let controller = window.controller else { return }
        let pick = suggestion ?? suggestions[safe: selection]
        switch pick {
        case .tab(let id, _, _):
            controller.tabs.activate(id)
        case .open(let url), .history(_, let url):
            controller.open(url, newTab: newTab)
        case .search(let q, _):
            if let url = Preferences.urlResolver.searchURL(for: q) { controller.open(url, newTab: newTab) }
        case nil:
            return
        }
        window.dismissCommandBar()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Large, centered "open anything" bar over the whole window, like Spotlight.
struct CommandBarOverlay: View {
    @Bindable var window: WindowModel

    var body: some View {
        ZStack(alignment: .top) {
            if let bar = window.commandBar {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { window.dismissCommandBar() }
                    .transition(.opacity)
                CommandBarCard(bar: bar, dismiss: { window.dismissCommandBar() })
                    .padding(.top, 96)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                                            removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)))
                    .id(bar.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: window.commandBar?.id)
        .appAccent()
    }
}

private struct CommandBarCard: View {
    @Bindable var bar: CommandBarModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: bar.newTab ? "plus.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(bar.newTab ? "Search or enter address" : "Search or enter address to open here", text: $bar.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($focused)
                    .onSubmit { bar.commit() }
                    .onKeyPress(.downArrow) { bar.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { bar.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                if !bar.query.isEmpty {
                    Button { bar.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            let suggestions = bar.suggestions
            if !suggestions.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            SuggestionRow(suggestion: suggestion, selected: index == bar.selection)
                                .contentShape(Rectangle())
                                .onTapGesture { bar.commit(suggestion) }
                                .onHover { if $0 { bar.selection = index } }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
        .onAppear { focused = true }
    }
}

private struct SuggestionRow: View {
    let suggestion: CommandBarModel.Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).font(.system(size: 14, weight: .medium))
                if let subtitle { Text(subtitle).lineLimit(1).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let badge { Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.55)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch suggestion {
        case .open: Image(systemName: "globe").foregroundStyle(.secondary)
        case .search: Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        case .tab(_, _, let url): FaviconView(url: url?.faviconGuess, size: 18)
        case .history: Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch suggestion {
        case .open(let url): return url.absoluteString
        case .search(let q, _): return q
        case .tab(_, let title, _), .history(let title, _): return title
        }
    }

    private var subtitle: String? {
        switch suggestion {
        case .tab(_, _, let url): return url?.host
        case .history(_, let url): return url.absoluteString
        default: return nil
        }
    }

    private var badge: String? {
        switch suggestion {
        case .open: return "Open"
        case .search(_, let engine): return "Search \(engine)"
        case .tab: return "Switch to Tab"
        case .history: return "History"
        }
    }
}

extension URL {
    /// `/favicon.ico` on the same origin, for places that have no page-reported icon.
    var faviconGuess: URL? {
        guard let scheme, scheme.hasPrefix("http"), let host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}
