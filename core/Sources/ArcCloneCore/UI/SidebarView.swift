import SwiftUI

/// The vertical tab sidebar, in SwiftUI.
struct SidebarView: View {
    @Bindable var window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            AddressPill(window: window)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)
            switch window.panel {
            case .tabs:
                VStack(spacing: 0) {
                    if !window.isPrivate, let space = window.currentSpace { SpaceHeader(space: space, window: window) }
                    TabListView(window: window)
                }
                .id(window.currentSpaceID)
                .transition(.push(from: window.spaceForward ? .trailing : .leading))
            case .assistant:
                AssistantPanelView(chat: window.assistant, window: window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .history:
                HistoryPanelView(window: window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            SidebarFooter(window: window)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .animation(.smooth(duration: 0.25), value: window.panel)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: window.currentSpaceID)
        .background(SidebarBackground(spaceColor: window.isPrivate ? nil : window.currentSpace?.color))
        .appAccent()
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

/// Pinned tabs as rounded tiles, then the regular tabs, where a split group shows as one pill
/// laid out like the split itself.
private struct TabListView: View {
    @Bindable var window: WindowModel

    var body: some View {
        List {
            if !window.pinnedTabs.isEmpty {
                PinnedGrid(window: window)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
            Section {
                ForEach(window.regularItems) { item in
                    switch item {
                    case .tab(let tab):
                        TabRow(tab: tab, window: window)
                            .listRowBackground(ActiveRowBackground(active: tab.id == window.activeID))
                    case .split(let layout, let members):
                        SplitPill(layout: layout, members: members, window: window)
                            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            .listRowBackground(Color.clear)
                    }
                }
                .onMove { window.moveItems(from: $0, to: $1) }
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
        .animation(.smooth(duration: 0.25), value: window.splitIDs)
    }
}

/// Arc-style pinned tabs: a grid of rounded tiles showing each site's icon.
private struct PinnedGrid: View {
    let window: WindowModel
    private let columns = [GridItem(.adaptive(minimum: 52, maximum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(window.pinnedTabs) { tab in PinnedTile(tab: tab, window: window) }
        }
    }
}

private struct PinnedTile: View {
    let tab: WindowModel.TabItem
    let window: WindowModel
    @State private var hovering = false
    @State private var dropTargeted = false
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent

    var body: some View {
        let active = tab.id == window.activeID
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? AnyShapeStyle(Color(hex: accent).opacity(0.28)) : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0.65)))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color(hex: accent).opacity(0.7) : (dropTargeted ? Color.accentColor : .clear), lineWidth: 1.5)
            FaviconView(url: tab.favicon ?? tab.url?.faviconGuess, size: 20)
            if tab.isLoading {
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(4)
            }
        }
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { window.activate(tab.id) }
        .onHover { hovering = $0 }
        .help(tab.title)
        .contextMenu { TabContextMenu(tab: tab, window: window) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            window.movePinned(id, before: tab.id)
            return true
        } isTargeted: { dropTargeted = $0 }
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

/// A split group: one rounded pill holding its tabs arranged like the split (side by side, stacked,
/// three columns/rows, or a 2×2 grid). Clicking a tab focuses it in the split.
private struct SplitPill: View {
    let layout: SplitLayout
    let members: [WindowModel.TabItem]
    let window: WindowModel
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent

    var body: some View {
        let isActive = members.contains { $0.id == window.activeID }
        Group {
            switch layout {
            case .twoColumns, .threeColumns:
                HStack(spacing: 3) { cells(members, compact: layout == .threeColumns) }
            case .twoRows, .threeRows:
                VStack(spacing: 3) { cells(members, compact: false) }
            case .grid:
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow { cells(Array(members.prefix(2)), compact: true) }
                    GridRow { cells(Array(members.dropFirst(2)), compact: true) }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? AnyShapeStyle(Color(hex: accent).opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5))))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isActive ? Color(hex: accent).opacity(0.45) : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Image(systemName: layout.symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary).padding(4)
        }
        .help(layout.title)
    }

    @ViewBuilder
    private func cells(_ tabs: [WindowModel.TabItem], compact: Bool) -> some View {
        ForEach(tabs) { tab in
            let focused = tab.id == window.activeID
            HStack(spacing: 5) {
                FaviconView(url: tab.favicon ?? tab.url?.faviconGuess, size: 14)
                if !compact { Text(tab.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail) }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, 7).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(focused ? AnyShapeStyle(Color(hex: accent).opacity(0.3)) : AnyShapeStyle(.background.opacity(0.35))))
            .contentShape(Rectangle())
            .onTapGesture { window.activate(tab.id) }
            .help(tab.title)
            .contextMenu { TabContextMenu(tab: tab, window: window) }
        }
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
            if tab.inSplit {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.tint).help("In Split View")
            }
            if hovering && !tab.isPinned {
                Button { window.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close Tab (⌘W)")
            }
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { window.activate(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu { TabContextMenu(tab: tab, window: window) }
    }
}

/// The active tab's highlight, in the user's accent color (Settings → Appearance).
private struct ActiveRowBackground: View {
    let active: Bool
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(active ? Color(hex: accent).opacity(0.22) : .clear)
            .padding(.horizontal, 6)
            .animation(.smooth(duration: 0.15), value: active)
    }
}

/// Right-click menu for a tab.
struct TabContextMenu: View {
    let tab: WindowModel.TabItem
    let window: WindowModel

    var body: some View {
        Button { window.newTab() } label: { Label("New Tab", systemImage: "plus.square") }
        Button { window.duplicate(tab.id) } label: { Label("Duplicate Tab", systemImage: "plus.square.on.square") }
        Button { window.reload(tab.id) } label: { Label("Reload", systemImage: "arrow.clockwise") }
        Divider()
        Button { window.setPinned(tab.id, !tab.isPinned) } label: {
            Label(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin")
        }
        Button { window.copyLink(tab.id) } label: { Label("Copy Link", systemImage: "link") }.disabled(tab.url == nil)
        if let url = tab.url { ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") } }
        Button { window.pauseMedia(tab.id) } label: { Label("Pause Media", systemImage: "pause.circle") }
        Divider()
        Button { window.openInNewWindow(tab.id) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
            .disabled(tab.url == nil)
        if window.spaces.count > 1 {
            Menu {
                ForEach(window.spaces.filter { $0.id != window.currentSpaceID }) { space in
                    Button { window.moveTab(tab.id, toSpace: space.id) } label: { Label(space.name, systemImage: space.symbol) }
                }
            } label: { Label("Move to Space", systemImage: "square.stack") }
        }
        if tab.inSplit {
            Button { window.removeFromSplit(tab.id) } label: { Label("Remove from Split View", systemImage: "rectangle.split.2x1.slash") }
        } else {
            if tab.id != window.activeID {
                Button { window.splitWithActive(tab.id) } label: { Label("Split with Current Tab", systemImage: "rectangle.split.2x1") }
            }
            if window.hasSplit && window.splitCanGrow {
                Button { window.addToSplit(tab.id) } label: { Label("Add to Split View", systemImage: "rectangle.split.3x1") }
            }
        }
        Divider()
        Button(role: .destructive) { window.close(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
        Button { window.closeOthers(tab.id) } label: { Label("Close Other Tabs", systemImage: "xmark.square") }
        Button { window.closeBelow(tab.id) } label: { Label("Close Tabs Below", systemImage: "arrow.down.to.line") }
    }
}

private struct SidebarFooter: View {
    @Bindable var window: WindowModel

    var body: some View {
        HStack(spacing: 2) {
            Button { window.showsAssistant.toggle() } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(window.showsAssistant ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(window.showsAssistant ? .primary : .secondary)
            .help("Assistant (⌘E)")
            if !window.isPrivate { SpaceSwitcher(window: window).frame(maxWidth: .infinity) } else { Spacer() }
            if window.controller?.history != nil {
                NavButton(symbol: "clock", help: "History") { window.panel = window.panel == .history ? .tabs : .history }
                    .foregroundStyle(window.panel == .history ? .primary : .secondary)
            }
            DownloadsButton(downloads: DownloadManager.shared, window: window)
            if window.canReopenClosed {
                NavButton(symbol: "arrow.uturn.backward", help: "Reopen Closed Tab (⇧⌘T)") { window.reopenClosed() }
            }
            NavButton(symbol: "plus", help: "New Tab (⌘T)") { window.newTab() }
        }
    }
}

// MARK: - Spaces

/// The current space's name above its tabs, with a menu to rename, restyle or delete it.
private struct SpaceHeader: View {
    let space: Space
    let window: WindowModel
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol).foregroundStyle(Color(hex: space.color)).font(.system(size: 11, weight: .semibold))
            Text(space.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button { editing = true } label: { Label("Edit Space…", systemImage: "pencil") }
                Button(role: .destructive) { window.deleteSpace(space.id) } label: { Label("Delete Space and Its Tabs", systemImage: "trash") }
                    .disabled(window.spaces.count < 2)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .popover(isPresented: $editing) { SpaceEditor(space: space, title: "Edit Space") { window.updateSpace($0) } }
    }
}

/// Space icons in the footer; click to switch, + to add. Two-finger swipes on the sidebar also switch.
private struct SpaceSwitcher: View {
    let window: WindowModel
    @State private var adding = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(window.spaces) { space in
                let current = space.id == window.currentSpaceID
                Button { window.switchSpace(to: space.id) } label: {
                    Image(systemName: space.symbol)
                        .font(.system(size: current ? 12 : 9, weight: .semibold))
                        .foregroundStyle(current ? Color(hex: space.color) : .secondary)
                        .frame(width: 20, height: 20)
                        .background(current ? Color(hex: space.color).opacity(0.18) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu {
                    Button(role: .destructive) { window.deleteSpace(space.id) } label: { Label("Delete Space", systemImage: "trash") }
                        .disabled(window.spaces.count < 2)
                }
            }
            Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New Space")
                .popover(isPresented: $adding) {
                    SpaceEditor(space: Space(name: "", symbol: Space.symbols.randomElement() ?? "circle.fill",
                                             color: AppearanceStyle.presets.randomElement() ?? AppearanceStyle.defaultAccent),
                                title: "New Space") { window.addSpace(name: $0.name, symbol: $0.symbol, color: $0.color) }
                }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: window.currentSpaceID)
    }
}

private struct SpaceEditor: View {
    @State var space: Space
    let title: String
    let save: (Space) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $space.name).textFieldStyle(.roundedBorder).onSubmit(commit)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 6), spacing: 6) {
                ForEach(Space.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .frame(width: 28, height: 28)
                        .background(space.symbol == symbol ? Color(hex: space.color).opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { space.symbol = symbol }
                }
            }
            HStack(spacing: 8) {
                ForEach(AppearanceStyle.presets, id: \.self) { hex in
                    Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.primary.opacity(space.color == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                        .onTapGesture { space.color = hex }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 260)
    }

    private func commit() {
        save(space)
        dismiss()
    }
}
