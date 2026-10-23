import AppKit
import SwiftUI

/// History (⌘Y): visits grouped by day, searchable; ⏎ or double-click opens, ⌫ deletes.
@MainActor
final class HistoryWindowController: NSWindowController {
    init(history: History, open: @escaping @MainActor (URL, Bool) -> Void) {
        let host = NSHostingController(rootView: HistoryView(history: history, open: open))
        let window = NSWindow(contentViewController: host)
        window.title = "History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.minSize = NSSize(width: 520, height: 360)
        window.setFrameAutosaveName("ArcCloneHistory")
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

struct HistoryView: View {
    @Bindable var history: History
    let open: @MainActor (URL, Bool) -> Void
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var confirmClearAll = false

    private struct Day: Identifiable {
        let id: Date
        let visits: [History.Visit]
    }

    private var days: [Day] {
        let visits = query.isEmpty ? history.visits : history.search(query, limit: 2_000)
        let calendar = Calendar.current
        return Dictionary(grouping: visits) { calendar.startOfDay(for: $0.visitedAt) }
            .map { Day(id: $0.key, visits: $0.value) }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search History", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Menu("Clear History") {
                    Button("The Last Hour") { history.clear(since: Date().addingTimeInterval(-3600)) }
                    Button("Today") { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                    Button("Today and Yesterday") {
                        history.clear(since: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())))
                    }
                    Divider()
                    Button("All History…") { confirmClearAll = true }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.top, 38).padding(.bottom, 10)

            if days.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No History" : "No Results",
                                       systemImage: query.isEmpty ? "clock" : "magnifyingglass",
                                       description: Text(query.isEmpty ? "Pages you visit in regular windows appear here. Private windows are never recorded." : "Nothing in your history matches “\(query)”."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(days) { day in
                        Section(dayTitle(day.id)) {
                            ForEach(day.visits) { HistoryRow(visit: $0).tag($0.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Open") { openSelected(ids, newTab: false) }
                    Button("Open in New Tab") { openSelected(ids, newTab: true) }
                    Button("Copy Link") { copy(ids) }
                    Divider()
                    Button("Delete") { history.remove(ids) }
                } primaryAction: { ids in
                    openSelected(ids, newTab: false)
                }
                .onDeleteCommand { history.remove(selection); selection.removeAll() }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .confirmationDialog("Clear all history?", isPresented: $confirmClearAll) {
            Button("Clear All History", role: .destructive) { history.clear() }
        } message: {
            Text("This removes every visited page from this Mac. Open tabs aren't affected.")
        }
    }

    private func visits(_ ids: Set<UUID>) -> [History.Visit] { history.visits.filter { ids.contains($0.id) } }

    private func openSelected(_ ids: Set<UUID>, newTab: Bool) {
        let chosen = visits(ids)
        for (index, visit) in chosen.enumerated() { open(visit.url, newTab || index > 0) }
    }

    private func copy(_ ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visits(ids).map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
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

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(url: visit.url.faviconGuess, size: 16)
            Text(visit.title.isEmpty ? visit.url.absoluteString : visit.title).lineLimit(1)
            Text(visit.url.host ?? "").lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(visit.visitedAt, format: .dateTime.hour().minute()).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
