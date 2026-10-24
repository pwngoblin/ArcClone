import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pinned tabs as tiles, in AppKit. An `NSCollectionView` gives native drag reordering (the
/// tiles part to show where a tab will land, at full frame rate) and animated changes from a
/// diffable data source, where the SwiftUI grid inside a list row relaid the whole row on every
/// change and re-checked each tile as a drop target while dragging.
///
/// Dragging a tile out gives the same pasteboard as a dragged list row (`TabDragDrop.swift`), so
/// it can be dropped into the list (unpins), on a space, a split, or into another app (its address).
struct PinnedTabsGrid: NSViewRepresentable {
    let window: WindowModel
    let tabs: [WindowModel.TabItem]
    let activeID: UUID?
    let accent: String

    func makeNSView(context: Context) -> PinnedTabsView { PinnedTabsView(window: window) }

    func updateNSView(_ view: PinnedTabsView, context: Context) {
        view.update(tabs: tabs, activeID: activeID, accent: NSColor(hex: accent))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PinnedTabsView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: PinnedTabsView.height(count: tabs.count, width: width))
    }
}

@MainActor
final class PinnedTabsView: NSView, NSCollectionViewDelegate {
    static let tileHeight: CGFloat = 44
    static let spacing: CGFloat = 8
    static let minTileWidth: CGFloat = 52

    static func columns(width: CGFloat) -> Int { max(1, Int((width + spacing) / (minTileWidth + spacing))) }

    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = CGFloat((count + columns(width: width) - 1) / columns(width: width))
        return rows * tileHeight + (rows - 1) * spacing
    }

    private let model: WindowModel
    private let scroll = PassThroughScrollView()
    private let collection = NSCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private lazy var source = NSCollectionViewDiffableDataSource<Int, UUID>(collectionView: collection) { [weak self] view, path, id in
        let item = view.makeItem(withIdentifier: PinnedTileItem.identifier, for: path)
        if let self, let tile = item as? PinnedTileItem, let tab = self.tabs[id] { self.configure(tile, tab) }
        return item
    }
    private var order: [UUID] = []
    private var tabs: [UUID: WindowModel.TabItem] = [:]
    private var activeID: UUID?
    private var accent = NSColor.controlAccentColor
    /// The insertion point shown during a drag, so the trackpad taps only when it moves.
    private var lastDropIndex: Int?

    init(window: WindowModel) {
        self.model = window
        super.init(frame: .zero)
        flowLayout.minimumInteritemSpacing = Self.spacing
        flowLayout.minimumLineSpacing = Self.spacing
        flowLayout.itemSize = NSSize(width: Self.minTileWidth, height: Self.tileHeight)
        collection.collectionViewLayout = flowLayout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true // drags start from selection; a click activates and clears it
        collection.delegate = self
        collection.register(PinnedTileItem.self, forItemWithIdentifier: PinnedTileItem.identifier)
        collection.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.lilyTab.identifier), .URL])
        collection.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        _ = source
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let columns = CGFloat(Self.columns(width: bounds.width))
        let width = floor((bounds.width - Self.spacing * (columns - 1)) / columns)
        if width > 0, flowLayout.itemSize.width != width {
            flowLayout.itemSize = NSSize(width: width, height: Self.tileHeight)
            flowLayout.invalidateLayout()
        }
    }

    func update(tabs items: [WindowModel.TabItem], activeID: UUID?, accent: NSColor) {
        let ids = items.map(\.id)
        tabs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.activeID = activeID
        self.accent = accent
        if ids != order {
            order = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            source.apply(snapshot, animatingDifferences: model.controller != nil)
        }
        // Titles, icons, loading and the active tile change in place, without a new snapshot.
        for case let tile as PinnedTileItem in collection.visibleItems() {
            if let id = tile.tabID, let tab = tabs[id] { configure(tile, tab) }
        }
    }

    private func configure(_ tile: PinnedTileItem, _ tab: WindowModel.TabItem) {
        tile.configure(tab, active: tab.id == activeID, accent: accent, remember: !model.isPrivate) { [weak self] in
            guard let self, let current = self.tabs[tab.id] else { return nil }
            return TabMenu.menu(for: current, window: self.model)
        }
    }

    // MARK: Clicks

    func collectionView(_ view: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) {
        if let path = paths.first, let id = source.itemIdentifier(for: path) { model.activate(id) }
        view.deselectAll(nil)
    }

    // MARK: Dragging out

    func collectionView(_ view: NSCollectionView, canDragItemsAt paths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ view: NSCollectionView, pasteboardWriterForItemAt path: IndexPath) -> (any NSPasteboardWriting)? {
        guard let id = source.itemIdentifier(for: path), let tab = tabs[id] else { return nil }
        return TabDrag.pasteboardItem(for: tab)
    }

    func collectionView(_ view: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt point: NSPoint,
                        forItemsAt paths: Set<IndexPath>) {
        Haptics.tap() // picked up
        lastDropIndex = nil
    }

    // MARK: Dropping in

    // The pointer parameters are how AppKit declares this delegate method; they're only written
    // to, through `pointee`.
    func collectionView(_ view: NSCollectionView, validateDrop info: any NSDraggingInfo,
                        proposedIndexPath path: AutoreleasingUnsafeMutablePointer<NSIndexPath>, // AppKit API signature
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation { // AppKit API signature
        guard let drop = TabDrag.read(info.draggingPasteboard) else { return [] }
        if case .link = drop, drop.webLink == nil { return [] }
        dropOperation.pointee = .before // between tiles, never onto one
        let index = path.pointee.item
        if index != lastDropIndex {
            if lastDropIndex != nil { Haptics.snap() }
            lastDropIndex = index
        }
        if case .tab = drop { return .move }
        return .copy
    }

    func collectionView(_ view: NSCollectionView, acceptDrop info: any NSDraggingInfo, indexPath path: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        lastDropIndex = nil
        guard let drop = TabDrag.read(info.draggingPasteboard) else { return false }
        // Before the tile now at that position; past the last one, after every pinned tab.
        let target = path.item < order.count ? order[path.item] : nil
        return model.dropOnPinned(drop, before: target)
    }

    func collectionView(_ view: NSCollectionView, draggingSession session: NSDraggingSession, endedAt point: NSPoint, dragOperation: NSDragOperation) {
        lastDropIndex = nil
    }
}

/// The grid's scroll view never scrolls itself: the sidebar list around it does.
private final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// One pinned tab: its icon on a rounded tile, accented when it's the active tab.
@MainActor
final class PinnedTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PinnedTile")
    private(set) var tabID: UUID?
    private let tile = PinnedTileView()

    override func loadView() { view = tile }

    func configure(_ tab: WindowModel.TabItem, active: Bool, accent: NSColor, remember: Bool, menu: @escaping () -> NSMenu?) {
        let changedTab = tabID != tab.id
        tabID = tab.id
        tile.menuProvider = menu
        tile.toolTip = tab.title
        tile.setAccessibilityLabel(tab.title)
        tile.style(active: active, loading: tab.isLoading, accent: accent)
        // A sleeping or restored pinned tab's site isn't open: its kept icon only, no request.
        let icon = tab.isSleeping ? nil : tab.favicon ?? tab.url?.faviconGuess
        if changedTab || icon != tile.iconURL || tab.url != tile.pageURL { tile.load(page: tab.url, fetch: icon, remember: remember) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tabID = nil
        tile.menuProvider = nil
    }
}

@MainActor
final class PinnedTileView: NSView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private var hovering = false { didSet { if hovering != oldValue { applyColors() } } }
    private var active = false
    private var accent = NSColor.controlAccentColor
    private(set) var iconURL: URL?
    private(set) var pageURL: URL?
    private var iconTask: Task<Void, Never>?
    /// The tab's context menu, built when it's asked for so it reflects the tab right now.
    var menuProvider: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4.4
        icon.layer?.masksToBounds = true
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        for view in [icon, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func style(active: Bool, loading: Bool, accent: NSColor) {
        self.active = active
        self.accent = accent
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        applyColors()
    }

    /// The site's icon: kept from a visit, or fetched only when the page is open (`FaviconLoader`).
    func load(page: URL?, fetch: URL?, remember: Bool) {
        iconTask?.cancel()
        iconURL = fetch
        pageURL = page
        show(FaviconLoader.shared.icon(forPage: page))
        guard let fetch else { return }
        iconTask = Task { [weak self] in
            guard let image = await FaviconLoader.shared.fetch(fetch, forPage: page, remember: remember), !Task.isCancelled,
                  let self, self.iconURL == fetch else { return }
            self.show(image)
        }
    }

    private func show(_ image: NSImage?) {
        icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? .tertiaryLabelColor : nil
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (active ? accent.withAlphaComponent(0.28)
                                      : NSColor.quaternaryLabelColor.withAlphaComponent(hovering ? 1 : 0.65)).cgColor
            layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
            layer?.borderWidth = active ? 1.5 : 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
