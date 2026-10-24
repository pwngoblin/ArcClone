import SwiftUI

/// History as a list in the sidebar: recent pages by day, filterable. Click opens in the current
/// tab, ⌘-click in a new one.
struct HistoryPanelView: View {
    let window: WindowModel
    @State private var query = ""

    private var history: History? { window.controller?.history }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search History", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 10)

            if let history {
                let visits = history.search(query, limit: 300)
                if visits.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No History Yet" : "No Results", systemImage: "clock",
                                           description: Text(query.isEmpty ? "Pages you visit appear here." : "Nothing matches “\(query)”."))
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(group(visits), id: \.day) { section in
                            Section(title(section.day)) {
                                ForEach(section.visits) { HistoryPanelRow(visit: $0, window: window) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            Button("Show All History…") { (NSApp.delegate as? AppDelegate)?.showHistory(nil) }
                .buttonStyle(.link).font(.caption).padding(.bottom, 2)
        }
    }

    private func group(_ visits: [History.Visit]) -> [(day: Date, visits: [History.Visit])] {
        let calendar = Calendar.current
        return Dictionary(grouping: visits) { calendar.startOfDay(for: $0.visitedAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.visitedAt > $1.visitedAt }) }
    }

    private func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
    }
}

private struct HistoryPanelRow: View {
    let visit: History.Visit
    let window: WindowModel

    var body: some View {
        Button {
            window.controller?.open(visit.url, newTab: NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: 8) {
                FaviconView(page: visit.url, size: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(visit.title.isEmpty ? visit.url.absoluteString : visit.title).lineLimit(1)
                    Text(visit.url.host ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(visit.visitedAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visit.url.absoluteString)
        .contextMenu {
            Button("Open") { window.controller?.open(visit.url, newTab: false) }
            Button("Open in New Tab") { window.controller?.open(visit.url, newTab: true) }
            Button("Copy Link") {
                Clipboard.copy(visit.url.absoluteString, sensitive: false)
            }
            Divider()
            Button("Delete from History") { window.controller?.history?.remove([visit.id]) }
        }
    }
}
