import SwiftUI

/// State for the centered command bar: open or search (⌘T / ⌘L), or the command palette (⌘K),
/// which also runs browser commands, switches spaces and opens extensions. In the palette, a
/// leading ">" shows commands only.
@MainActor @Observable
final class CommandBarModel: Identifiable {
    enum Suggestion: Identifiable, Equatable {
        case open(URL)
        case search(String, engine: String)
        case tab(id: UUID, title: String, url: URL?)
        case history(title: String, url: URL)
        case bookmark(title: String, url: URL)
        case command(PaletteCommand)

        var id: String {
            switch self {
            case .open(let url): return "open:\(url.absoluteString)"
            case .search(let q, _): return "search:\(q)"
            case .tab(let id, _, _): return "tab:\(id.uuidString)"
            case .history(_, let url): return "history:\(url.absoluteString)"
            case .bookmark(_, let url): return "bookmark:\(url.absoluteString)"
            case .command(let command): return command.id
            }
        }
    }

    let id = UUID()
    let newTab: Bool
    let isPalette: Bool
    var query: String { didSet { selection = 0 } }
    var selection = 0
    @ObservationIgnored private weak var window: WindowModel?
    /// Read once when the palette opens (menu validation isn't free), not per keystroke.
    @ObservationIgnored private let commands: [PaletteCommand]
    /// SwiftUI reads `suggestions` several times per keystroke; history and bookmark search run once.
    @ObservationIgnored private var cached: (query: String, suggestions: [Suggestion])?

    init(newTab: Bool, query: String, window: WindowModel, palette: Bool = false) {
        self.newTab = newTab
        self.query = query
        self.window = window
        isPalette = palette
        commands = palette ? PaletteCommands.all(in: window) : []
    }

    var suggestions: [Suggestion] {
        if let cached, cached.query == query { return cached.suggestions }
        let result = computeSuggestions()
        cached = (query, result)
        return result
    }

    /// Commands matching `query`, best first (all of them, in menu order, for an empty query).
    private func matchingCommands(_ query: String, limit: Int) -> [Suggestion] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return commands.prefix(limit).map(Suggestion.command) }
        return commands.enumerated()
            .compactMap { index, command in command.score(words).map { (score: $0, index: index, command: command) } }
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .prefix(limit).map { .command($0.command) }
    }

    private func computeSuggestions() -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPalette, q.hasPrefix(">") || q.isEmpty {
            return matchingCommands(String(q.dropFirst(q.hasPrefix(">") ? 1 : 0)).trimmingCharacters(in: .whitespaces), limit: 60)
        }
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
        if let bookmarks = window.controller?.bookmarks {
            let open = Set(out.compactMap { if case .tab(_, _, let url) = $0 { url } else { nil } })
            for link in bookmarks.search(q, limit: 3) where !open.contains(link.url!) {
                out.append(.bookmark(title: link.title.isEmpty ? link.url!.absoluteString : link.title, url: link.url!))
            }
        }
        if let history = window.controller?.history {
            let open = Set(out.compactMap { suggestion -> URL? in
                switch suggestion {
                case .tab(_, _, let url): return url
                case .bookmark(_, let url): return url
                default: return nil
                }
            })
            for visit in history.search(q, limit: 12) where !open.contains(visit.url) {
                out.append(.history(title: visit.title.isEmpty ? visit.url.absoluteString : visit.title, url: visit.url))
                if out.count >= 9 { break }
            }
        }
        // Commands that match go right after "open" and "search", ahead of pages.
        if isPalette { out.insert(contentsOf: matchingCommands(q, limit: 3), at: min(out.count, 2)) }
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
        case .open(let url), .history(_, let url), .bookmark(_, let url):
            controller.open(url, newTab: newTab)
        case .search(let q, _):
            if let url = Preferences.urlResolver.searchURL(for: q) { controller.open(url, newTab: newTab) }
        case .command(let command):
            Haptics.tap()
            window.dismissCommandBar()
            command.perform(in: window)
            return
        case nil:
            return
        }
        Haptics.tap()
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
                Image(systemName: bar.isPalette ? "command" : bar.newTab ? "plus.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(bar.isPalette ? "Search tabs, history and bookmarks, or type > for commands"
                          : bar.newTab ? "Search or enter address" : "Search or enter address to open here", text: $bar.query)
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
        case .tab(_, _, let url): FaviconView(page: url, size: 18) // may be asleep: kept icons only
        case .history: Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
        case .bookmark: Image(systemName: "bookmark.fill").foregroundStyle(.tint)
        case .command(let command): Image(systemName: command.symbol).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch suggestion {
        case .open(let url): return url.absoluteString
        case .search(let q, _): return q
        case .tab(_, let title, _), .history(let title, _), .bookmark(let title, _): return title
        case .command(let command): return command.title
        }
    }

    private var subtitle: String? {
        switch suggestion {
        case .tab(_, _, let url): return url?.host
        case .history(_, let url), .bookmark(_, let url): return url.absoluteString
        case .command(let command): return command.path.isEmpty ? nil : command.path
        default: return nil
        }
    }

    private var badge: String? {
        switch suggestion {
        case .open: return "Open"
        case .search(_, let engine): return "Search \(engine)"
        case .tab: return "Switch to Tab"
        case .history: return "History"
        case .bookmark: return "Bookmark"
        case .command(let command): return command.shortcut ?? "Command"
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
