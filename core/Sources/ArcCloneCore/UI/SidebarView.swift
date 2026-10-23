import SwiftUI

/// Height of the title row: tall enough that the navigation buttons sit level with the traffic
/// lights of the unified toolbar-style title bar instead of colliding with them.
let titleRowHeight: CGFloat = 52
/// Room the traffic lights take on the left of the title row.
let trafficLightsWidth: CGFloat = 78

/// The vertical tab sidebar, in SwiftUI.
struct SidebarView: View {
    @Bindable var window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            NavRow(window: window)
                .frame(height: titleRowHeight)
            AddressPill(window: window)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            if window.showsAssistant {
                AssistantPanelView(chat: window.assistant, window: window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                TabListView(window: window)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            SidebarFooter(window: window)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .animation(.smooth(duration: 0.25), value: window.showsAssistant)
        .overlay(alignment: .bottom) {
            if let toast = window.toast {
                Text(toast.message)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: window.toast)
    }
}

private struct NavRow: View {
    let window: WindowModel

    var body: some View {
        HStack(spacing: 2) {
            Spacer().frame(width: trafficLightsWidth)
            NavButton(symbol: "sidebar.left", help: "Hide Sidebar (⌘S)") { window.toggleSidebar() }
            Spacer()
            NavButton(symbol: "chevron.left", help: "Back (⌘[)", enabled: window.canGoBack) { window.goBack() }
            NavButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: window.canGoForward) { window.goForward() }
            NavButton(symbol: window.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise",
                      help: "Reload (⌘R)", enabled: window.activeTab != nil) { window.reloadOrStop() }
        }
        .padding(.trailing, 8)
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .tertiary)
        .disabled(!enabled)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Shows the active page's address; clicking it opens the command bar on that URL (⌘L).
private struct AddressPill: View {
    let window: WindowModel
    @State private var hovering = false

    var body: some View {
        let url = window.activeTab?.url
        Button { window.presentCommandBar(newTab: false) } label: {
            HStack(spacing: 7) {
                Image(systemName: url?.scheme == "https" ? "lock.fill" : (url == nil ? "magnifyingglass" : "exclamationmark.triangle"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(url?.scheme == "http" ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                Text(display(url)).lineLimit(1).truncationMode(.middle).font(.system(size: 13))
                    .foregroundStyle(url == nil ? .tertiary : .primary)
                Spacer(minLength: 0)
                if window.isPrivate {
                    Label("Private", systemImage: "eyeglasses").labelStyle(.iconOnly).foregroundStyle(.secondary).help("Private window")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.quaternary.opacity(hovering ? 1.0 : 0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Location (⌘L)")
    }

    private func display(_ url: URL?) -> String {
        guard let url else { return "Search or enter address" }
        guard let host = url.host, url.scheme?.hasPrefix("http") == true else { return url.absoluteString }
        let path = url.path == "/" ? "" : url.path
        return host.replacingOccurrences(of: "www.", with: "", options: .anchored) + path
    }
}

/// Pinned and regular tabs, with native drag-to-reorder and per-tab context menus.
private struct TabListView: View {
    @Bindable var window: WindowModel

    var body: some View {
        List(selection: Binding(get: { window.activeID }, set: { if let id = $0 { window.activate(id) } })) {
            if !window.pinnedTabs.isEmpty {
                Section("Pinned") {
                    ForEach(window.pinnedTabs) { tab in TabRow(tab: tab, window: window).tag(tab.id) }
                        .onMove { window.move(in: window.pinnedTabs, from: $0, to: $1) }
                }
            }
            Section(window.pinnedTabs.isEmpty ? "" : "Today") {
                ForEach(window.regularTabs) { tab in TabRow(tab: tab, window: window).tag(tab.id) }
                    .onMove { window.move(in: window.regularTabs, from: $0, to: $1) }
                Button { window.newTab() } label: {
                    Label("New Tab", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .animation(.smooth(duration: 0.2), value: window.tabs.map(\.id))
    }
}

private struct TabRow: View {
    let tab: WindowModel.TabItem
    let window: WindowModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                FaviconView(url: tab.favicon ?? tab.url?.faviconGuess, size: 16)
                if tab.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.8) }
            }
            .frame(width: 18)
            Text(tab.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering && !tab.isPinned {
                Button { window.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close Tab (⌘W)")
            }
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { TabContextMenu(tab: tab, window: window) }
    }
}

/// Right-click menu for a tab.
struct TabContextMenu: View {
    let tab: WindowModel.TabItem
    let window: WindowModel

    var body: some View {
        Button("New Tab") { window.newTab() }
        Button("Duplicate Tab") { window.duplicate(tab.id) }
        Button("Reload") { window.reload(tab.id) }
        Divider()
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { window.setPinned(tab.id, !tab.isPinned) }
        Button("Copy Link") { window.copyLink(tab.id) }.disabled(tab.url == nil)
        if let url = tab.url { ShareLink("Share…", item: url) }
        Button("Pause Media") { window.pauseMedia(tab.id) }
        Divider()
        Button("Open in New Window") { window.openInNewWindow(tab.id) }.disabled(tab.url == nil)
        Divider()
        Button("Close Tab") { window.close(tab.id) }
        Button("Close Other Tabs") { window.closeOthers(tab.id) }
        Button("Close Tabs Below") { window.closeBelow(tab.id) }
    }
}

private struct SidebarFooter: View {
    @Bindable var window: WindowModel

    var body: some View {
        HStack(spacing: 2) {
            Button { window.showsAssistant.toggle() } label: {
                Label("Assistant", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(window.showsAssistant ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(window.showsAssistant ? .primary : .secondary)
            .help("Assistant (⌘E)")
            if window.canReopenClosed {
                NavButton(symbol: "arrow.uturn.backward", help: "Reopen Closed Tab (⇧⌘T)") { window.reopenClosed() }
            }
            NavButton(symbol: "plus", help: "New Tab (⌘T)") { window.newTab() }
        }
    }
}
