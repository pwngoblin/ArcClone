import AppKit
import SwiftUI

/// History (⌘Y): a sidebar of time ranges and most-visited sites, and a searchable list of visits
/// grouped by day. ⏎ / double-click opens, ⌫ deletes, ⌘A selects all.
@MainActor
final class HistoryWindowController: NSWindowController {
    init(history: History, open: @escaping @MainActor (URL, Bool) -> Void) {
        let host = NSHostingController(rootView: HistoryView(history: history, open: open).appAccent())
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = "History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 920, height: 640))
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("LilyHistory")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the history list is filtered to.
enum HistoryFilter: Hashable {
    case all, today, yesterday, week, month, older
    case site(String)

    var title: String {
        switch self {
        case .all: return "All History"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        case .older: return "Older"
        case .site(let host): return host
        }
    }

    var symbol: String {
        switch self {
        case .all: return "clock"
        case .today: return "sun.max"
        case .yesterday: return "moon"
        case .week: return "calendar"
        case .month: return "calendar.badge.clock"
        case .older: return "archivebox"
        case .site: return "globe"
        }
    }

    func matches(_ visit: History.Visit, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: today)! }
        switch self {
        case .all: return true
        case .today: return visit.visitedAt >= today
        case .yesterday: return visit.visitedAt >= day(-1) && visit.visitedAt < today
        case .week: return visit.visitedAt >= day(-6)
        case .month: return visit.visitedAt >= day(-29)
        case .older: return visit.visitedAt < day(-29)
        case .site(let host): return HistoryFilter.host(of: visit.url) == host
        }
    }

    static func host(of url: URL) -> String {
        let host = url.host?.lowercased() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Hosts by visit count, most visited first.
    static func topSites(_ visits: [History.Visit], limit: Int = 12) -> [(host: String, count: Int)] {
        Dictionary(grouping: visits, by: { host(of: $0.url) })
            .map { (host: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }
            .prefix(limit).map { $0 }
    }
}

struct HistoryView: View {
    @Bindable var history: History
    let open: @MainActor (URL, Bool) -> Void
    @State private var filter: HistoryFilter? = .all
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var confirmClearAll = false

    private var filtered: [History.Visit] {
        let base = (filter ?? .all)
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        return history.visits.filter { visit in
            base.matches(visit) && (needle.isEmpty || visit.title.lowercased().contains(needle) || visit.url.absoluteString.lowercased().contains(needle))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section {
                    let counts = rangeCounts
                    ForEach([HistoryFilter.all, .today, .yesterday, .week, .month, .older], id: \.self) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(counts[item] ?? 0)
                            .tag(item)
                    }
                }
                let sites = HistoryFilter.topSites(history.visits)
                if !sites.isEmpty {
                    Section("Most Visited") {
                        ForEach(sites, id: \.host) { site in
                            Label { Text(site.host).lineLimit(1) } icon: { FaviconView(url: URL(string: "https://\(site.host)/favicon.ico"), size: 16) }
                                .badge(site.count)
                                .tag(HistoryFilter.site(site.host))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            detail
                .navigationTitle((filter ?? .all).title)
                .navigationSubtitle("\(filtered.count) \(filtered.count == 1 ? "page" : "pages")")
                .searchable(text: $query, placement: .toolbar, prompt: "Search History")
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Button("The Last Hour") { history.clear(since: Date().addingTimeInterval(-3600)) }
                            Button("Today") { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                            Button("Today and Yesterday") {
                                history.clear(since: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())))
                            }
                            Divider()
                            Button("All History…") { confirmClearAll = true }
                        } label: { Label("Clear History", systemImage: "trash") }
                        .help("Clear History")
                    }
                }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClearAll) {
            Button("Clear All History", role: .destructive) { history.clear() }
        } message: {
            Text("This removes every visited page from this Mac. Open tabs aren't affected.")
        }
    }

    @ViewBuilder private var detail: some View {
        let visits = filtered
        if visits.isEmpty {
            ContentUnavailableView {
                Label(query.isEmpty ? "No History" : "No Results", systemImage: query.isEmpty ? "clock" : "magnifyingglass")
            } description: {
                Text(query.isEmpty ? "Pages you visit in regular windows appear here. Private windows are never recorded."
                                   : "Nothing in \((filter ?? .all).title.lowercased()) matches “\(query)”.")
            }
        } else {
            List(selection: $selection) {
                ForEach(days(visits), id: \.day) { group in
                    Section {
                        ForEach(group.visits) { visit in
                            HistoryRow(visit: visit, open: open, delete: { history.remove([visit.id]) }).tag(visit.id)
                        }
                    } header: {
                        Text(dayTitle(group.day)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button { openSelected(ids, newTab: false) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                Button { openSelected(ids, newTab: true) } label: { Label("Open in New Tab", systemImage: "plus.square.on.square") }
                Button { copy(ids) } label: { Label("Copy Link", systemImage: "link") }
                Divider()
                Button(role: .destructive) { history.remove(ids) } label: { Label("Delete", systemImage: "trash") }
            } primaryAction: { ids in
                openSelected(ids, newTab: false)
            }
            .onDeleteCommand { history.remove(selection); selection.removeAll() }
        }
    }

    /// All range badges in one pass over the history instead of one pass per range.
    private var rangeCounts: [HistoryFilter: Int] {
        let ranges: [HistoryFilter] = [.today, .yesterday, .week, .month, .older]
        var counts: [HistoryFilter: Int] = [.all: history.visits.count]
        let now = Date()
        for visit in history.visits {
            for range in ranges where range.matches(visit, now: now) { counts[range, default: 0] += 1 }
        }
        return counts
    }

    private func days(_ visits: [History.Visit]) -> [(day: Date, visits: [History.Visit])] {
        let calendar = Calendar.current
        return Dictionary(grouping: visits) { calendar.startOfDay(for: $0.visitedAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.visitedAt > $1.visitedAt }) }
    }

    private func openSelected(_ ids: Set<UUID>, newTab: Bool) {
        let chosen = history.visits.filter { ids.contains($0.id) }
        for (index, visit) in chosen.enumerated() { open(visit.url, newTab || index > 0) }
    }

    private func copy(_ ids: Set<UUID>) {
        Clipboard.copy(history.visits.filter { ids.contains($0.id) }.map(\.url.absoluteString).joined(separator: "\n"), sensitive: false)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

private struct HistoryRow: View {
    let visit: History.Visit
    let open: @MainActor (URL, Bool) -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FaviconView(url: visit.url.faviconGuess, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(location).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if hovering {
                Button { open(visit.url, true) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open in New Tab")
                Button(action: delete) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete from History")
            }
            Text(visit.visitedAt, format: .dateTime.hour().minute())
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var location: String {
        let host = HistoryFilter.host(of: visit.url)
        let path = visit.url.path == "/" ? "" : visit.url.path
        return host + path
    }
}
