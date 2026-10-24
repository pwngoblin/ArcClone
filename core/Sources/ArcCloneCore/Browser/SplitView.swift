import AppKit
import WebKit

/// The ways the content area can be divided between tabs.
public enum SplitLayout: String, CaseIterable, Codable, Sendable {
    case twoColumns, twoRows, threeColumns, threeRows, grid

    public var paneCount: Int {
        switch self {
        case .twoColumns, .twoRows: return 2
        case .threeColumns, .threeRows: return 3
        case .grid: return 4
        }
    }

    var title: String {
        switch self {
        case .twoColumns: return "Two Side by Side"
        case .twoRows: return "Two Stacked"
        case .threeColumns: return "Three Columns"
        case .threeRows: return "Three Rows"
        case .grid: return "Four in a Grid"
        }
    }

    var symbol: String {
        switch self {
        case .twoColumns: return "rectangle.split.2x1"
        case .twoRows: return "rectangle.split.1x2"
        case .threeColumns: return "rectangle.split.3x1"
        case .threeRows: return "rectangle.split.1x3"
        case .grid: return "rectangle.split.2x2"
        }
    }

    /// Layout after one pane closes (nil: the split ends).
    var shrunk: SplitLayout? {
        switch self {
        case .twoColumns, .twoRows: return nil
        case .threeColumns: return .twoColumns
        case .threeRows: return .twoRows
        case .grid: return .threeColumns
        }
    }

    /// Layout after adding a pane (nil: already four).
    var grown: SplitLayout? {
        switch self {
        case .twoColumns: return .threeColumns
        case .twoRows: return .threeRows
        case .threeColumns, .threeRows: return .grid
        case .grid: return nil
        }
    }
}

/// Tabs shown together, in pane order.
public struct SplitGroup: Equatable, Sendable {
    public var layout: SplitLayout
    public var tabIDs: [UUID]
    /// Link Scrolling: scrolling one pane scrolls the others to the same place (`scroll-sync.js`).
    public var scrollLinked = false

    /// Drops a closed tab, shrinking the layout; nil when fewer than two tabs remain.
    func removing(_ id: UUID) -> SplitGroup? {
        var group = self
        group.tabIDs.removeAll { $0 == id }
        while group.tabIDs.count < group.layout.paneCount {
            guard let smaller = group.layout.shrunk else { return nil }
            group.layout = smaller
        }
        return group
    }

    func adding(_ id: UUID) -> SplitGroup? {
        guard !tabIDs.contains(id), let bigger = layout.grown else { return nil }
        var group = self
        group.layout = bigger
        group.tabIDs.append(id)
        return group
    }
}

/// Right-hand pane: the active tab, or the active split group, as rounded cards. Clicking a pane
/// focuses its tab; the focused pane wears the accent color.
@MainActor
final class TabContentViewController: NSViewController {
    private let container = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private var panes: [PaneView] = []
    private var shown: (layout: SplitLayout?, ids: [UUID]) = (nil, [])
    private var clickMonitor: Any?
    /// Called when the user clicks into a pane that isn't the active tab.
    var onFocus: (@MainActor (UUID) -> Void)?

    override func loadView() {
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            container.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.focusPane(at: event) }
            return event
        }
    }

    func tearDown() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Shows `active` alone, or its split group when it belongs to one.
    func display(active: Tab?, split: SplitGroup?, lookup: (UUID) -> Tab?) {
        _ = view
        emptyLabel.isHidden = active != nil
        guard let active else { rebuild(layout: nil, tabs: []); return }
        if let split, split.tabIDs.contains(active.id) {
            let tabs = split.tabIDs.compactMap(lookup)
            if shown.layout != split.layout || shown.ids != tabs.map(\.id) { rebuild(layout: split.layout, tabs: tabs) }
        } else if shown.layout != nil || shown.ids != [active.id] {
            rebuild(layout: nil, tabs: [active])
        }
        panes.forEach { $0.isFocused = panes.count > 1 && $0.tabID == active.id }
    }

    private func rebuild(layout: SplitLayout?, tabs: [Tab]) {
        container.subviews.forEach { $0.removeFromSuperview() }
        panes = tabs.map { PaneView(tab: $0) }
        shown = (layout, tabs.map(\.id))
        guard !panes.isEmpty else { return }
        let content: NSView
        switch layout {
        case nil: content = panes[0]
        case .twoColumns, .threeColumns: content = Self.split(panes, vertical: true)
        case .twoRows, .threeRows: content = Self.split(panes, vertical: false)
        case .grid:
            content = Self.split([Self.split(Array(panes.prefix(2)), vertical: true),
                                  Self.split(Array(panes.dropFirst(2)), vertical: true)], vertical: false)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if layout != nil {
            Haptics.step()
            content.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                content.animator().alphaValue = 1
            }
        }
    }

    private static func split(_ views: [NSView], vertical: Bool) -> NSSplitView {
        let split = EvenSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        views.forEach(split.addArrangedSubview)
        return split
    }

    private func focusPane(at event: NSEvent) {
        guard panes.count > 1, event.window === view.window,
              let pane = panes.first(where: { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }),
              !pane.isFocused else { return }
        onFocus?(pane.tabID)
    }
}

/// Splits its space evenly the first time it is laid out; the user can then drag the dividers.
private final class EvenSplitView: NSSplitView {
    private var distributed = false

    override func layout() {
        super.layout()
        guard !distributed, arrangedSubviews.count > 1 else { return }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(arrangedSubviews.count - 1)
        guard total > 0 else { return }
        distributed = true
        let share = total / CGFloat(arrangedSubviews.count)
        for index in 0..<(arrangedSubviews.count - 1) {
            setPosition(share * CGFloat(index + 1) + dividerThickness * CGFloat(index), ofDividerAt: index)
        }
    }
}

/// One rounded card holding a tab's web view.
private final class PaneView: NSView {
    let tabID: UUID
    var isFocused = false { didSet { updateBorder() } }

    init(tab: Tab) {
        tabID = tab.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        let web = tab.webView
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        let accent = NSColor(hex: UserDefaults.standard.string(forKey: AppearanceStyle.Key.accent) ?? AppearanceStyle.defaultAccent)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = isFocused ? 2 : 0.5
            layer?.borderColor = (isFocused ? accent : NSColor.separatorColor).cgColor
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).prefix(6)
        let value = UInt32(digits, radix: 16) ?? 0x5B4CF5
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
