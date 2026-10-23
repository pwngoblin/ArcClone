import SwiftUI
import UniformTypeIdentifiers

/// The sidebar footer's downloads button: a progress ring while downloading, a count badge, and a
/// bounce whenever a new download starts.
struct DownloadsButton: View {
    @Bindable var downloads: DownloadManager
    let window: WindowModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            ZStack {
                if let fraction = downloads.overallFraction {
                    Circle().stroke(.quaternary, lineWidth: 2).frame(width: 20, height: 20)
                    Circle().trim(from: 0, to: max(0.03, fraction))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .animation(.smooth, value: fraction)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .symbolEffect(.bounce, value: downloads.startCount)
            }
            .frame(width: 30, height: 28)
            .overlay(alignment: .topTrailing) {
                if downloads.activeCount > 0 {
                    Text("\(downloads.activeCount)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                        .background(.tint, in: Capsule())
                        .offset(x: 2, y: -2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(downloads.items.isEmpty ? .secondary : .primary)
        .help("Downloads")
        .background(GeometryReader { proxy in
            Color.clear.preference(key: DownloadsButtonFrameKey.self, value: proxy.frame(in: .global))
        })
        .onPreferenceChange(DownloadsButtonFrameKey.self) { frame in window.downloadsButtonFrame = frame }
        .popover(isPresented: $showing, arrowEdge: .top) {
            DownloadsListView(downloads: downloads, window: window)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: downloads.activeCount)
    }
}

struct DownloadsButtonFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct DownloadsListView: View {
    @Bindable var downloads: DownloadManager
    let window: WindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .controlSize(.small)
                    .disabled(!downloads.items.contains { !$0.isActive })
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            if downloads.items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Files you download appear here and are saved to your Downloads folder."))
                    .frame(height: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(downloads.items) { DownloadRow(item: $0, downloads: downloads, window: window) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 360)
    }
}

private struct DownloadRow: View {
    let item: DownloadManager.Item
    let downloads: DownloadManager
    let window: WindowModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(1).truncationMode(.middle).font(.system(size: 13, weight: .medium))
                if item.isActive {
                    if let fraction = item.fraction { ProgressView(value: fraction).controlSize(.small) }
                    else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                }
                Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                switch item.state {
                case .downloading:
                    action("xmark.circle.fill", "Cancel") { downloads.cancel(item.id) }
                case .finished:
                    action("magnifyingglass.circle.fill", "Show in Finder") { downloads.reveal(item.id) }
                case .failed, .cancelled:
                    action("arrow.clockwise.circle.fill", "Retry") { downloads.retry(item.id, in: window.controller?.tabs.active?.webView) }
                }
                if !item.isActive && hovering { action("minus.circle", "Remove from List") { downloads.remove(item.id) } }
            }
        }
        .padding(8)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { downloads.open(item.id) }
        .contextMenu {
            Button { downloads.open(item.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }.disabled(item.state != .finished)
            Button { downloads.reveal(item.id) } label: { Label("Show in Finder", systemImage: "folder") }.disabled(item.destination == nil)
            if let source = item.source {
                Button { Clipboard.copy(source.absoluteString, sensitive: window.isPrivate) } label: { Label("Copy Download Link", systemImage: "link") }
            }
            Divider()
            Button { downloads.remove(item.id) } label: { Label("Remove from List", systemImage: "minus.circle") }.disabled(item.isActive)
        }
    }

    private var icon: NSImage {
        if let url = item.destination, item.state == .finished { return NSWorkspace.shared.icon(forFile: url.path) }
        let ext = (item.filename as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private var status: String {
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch item.state {
        case .downloading:
            guard item.totalBytes > 0 else { return item.receivedBytes > 0 ? bytes(item.receivedBytes) : "Starting…" }
            var text = "\(bytes(item.receivedBytes)) of \(bytes(item.totalBytes))"
            let elapsed = Date().timeIntervalSince(item.startedAt)
            if item.receivedBytes > 0, elapsed > 1 {
                let remaining = Double(item.totalBytes - item.receivedBytes) / (Double(item.receivedBytes) / elapsed)
                text += " — \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))) left"
            }
            return text
        case .finished: return item.totalBytes > 0 ? bytes(item.totalBytes) : "Done"
        case .failed(let message): return "Failed: \(message)"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        if case .failed = item.state { return .red }
        return .secondary
    }

    private func action(_ symbol: String, _ help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).font(.system(size: 16)).symbolRenderingMode(.hierarchical) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
}
