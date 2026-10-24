import AppKit
import SwiftUI

/// File → Import from Another Browser…
@MainActor
final class MigrationWindowController: NSWindowController {
    init(model: MigrationModel) {
        let host = NSHostingController(rootView: MigrationView(model: model) { [weak model] in model?.reset() }.appAccent())
        let window = NSWindow(contentViewController: host)
        window.title = "Import from Another Browser"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 760, height: 640))
        window.minSize = NSSize(width: 560, height: 520)
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

/// The import dashboard: grant access, pick browsers and what to bring, watch progress, see results.
struct MigrationView: View {
    @Bindable var model: MigrationModel
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.phase {
            case .idle: selection
            case .importing(let step, let progress): importing(step, progress)
            case .done(let summary): finished(summary)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task { await model.appear() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Bring Your Web With You").font(.system(size: 22, weight: .semibold))
            Text("Bookmarks, history and Arc spaces from your other browsers are merged into ArcClone, without duplicates. Nothing in those browsers is changed, and everything imported is encrypted on this Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .padding(.top, 34).padding(.bottom, 18).padding(.horizontal, 24)
    }

    // MARK: Selection

    private var selection: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(MigrationRoot.allCases.filter { !model.grantedRoots.contains($0) }, id: \.self) { root in
                        AccessBanner(root: root) { Task { await model.grant(root) } }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(model.cards) { card in
                            BrowserCard(card: card, model: model)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                Spacer()
                Button { Task { await model.start() } } label: { Text("Import").frame(minWidth: 80) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.canImport)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    // MARK: Progress

    private func importing(_ step: String, _ progress: Double) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: progress).frame(maxWidth: 380)
            Text(step).font(.callout).foregroundStyle(.secondary).contentTransition(.opacity)
                .animation(.smooth, value: step)
            Spacer()
        }
        .padding(30)
    }

    // MARK: Done

    private func finished(_ summary: MigrationModel.Summary) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: summary.browsers.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.system(size: 48)).foregroundStyle(summary.browsers.isEmpty ? Color.orange : Color.green)
                .symbolEffect(.bounce, value: summary.browsers.count)
            Text(summary.browsers.isEmpty ? "Nothing was imported" : "Welcome home").font(.system(size: 20, weight: .semibold))
            if !summary.browsers.isEmpty {
                Text(Self.headline(summary)).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 480)
                HStack(spacing: 22) {
                    Stat(value: summary.bookmarks, label: "Bookmarks", symbol: "bookmark.fill")
                    Stat(value: summary.history, label: "History", symbol: "clock.fill")
                    if summary.spaces > 0 { Stat(value: summary.tabs, label: "Tabs in \(summary.spaces) spaces", symbol: "square.stack.fill") }
                }
                .padding(.top, 4)
            }
            if summary.olderThanRetention > 0 {
                Text("\(summary.olderThanRetention.formatted()) history entries were older than your history setting (Settings → Privacy) and were skipped.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            ForEach(summary.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).frame(maxWidth: 480)
            }
            Spacer()
            HStack {
                Button("Import More") { onFinished() }
                Spacer()
                Button { NSApp.keyWindow?.close() } label: { Text("Open Browser").frame(minWidth: 100) }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .padding(.horizontal, 24)
    }

    static func headline(_ summary: MigrationModel.Summary) -> String {
        let browsers = summary.browsers.formatted(.list(type: .and))
        return "Merged \(browsers): \(summary.bookmarks.formatted()) bookmarks and \(summary.history.formatted()) history entries unified."
    }
}

private struct AccessBanner: View {
    let root: MigrationRoot
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.system(size: 22)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(root == .safari ? "Allow access to Safari" : "Allow access to Chrome, Arc, Dia and Zen").font(.headline)
                Text("ArcClone can only read \(root.displayPath) after you choose it. Access is read-only and remembered for next time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Grant Access…", action: grant).controlSize(.large)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.08)))
    }
}

private struct BrowserCard: View {
    let card: MigrationModel.Card
    let model: MigrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BrowserIcon(browser: card.browser).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.browser.displayName).font(.system(size: 14, weight: .semibold))
                    status
                }
                Spacer()
                Toggle("", isOn: Binding(get: { card.selected }, set: { on in model.update(card.id) { $0.selected = on } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(!card.isAvailable)
            }
            if card.isAvailable {
                DisclosureGroup(isExpanded: Binding(get: { card.expanded }, set: { open in model.update(card.id) { $0.expanded = open } })) {
                    VStack(alignment: .leading, spacing: 6) {
                        option("Bookmarks & Folders", \.bookmarks)
                        option("Browsing History", \.history)
                        if card.browser.supportsSpaces { option("Saved Tabs & Spaces", \.spaces) }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("What to import").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!card.selected)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(card.selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: card.selected ? 1.5 : 0.5))
        .opacity(card.isAvailable || card.status == .scanning ? 1 : 0.75)
        .animation(.smooth(duration: 0.2), value: card.selected)
    }

    private func option(_ title: String, _ key: WritableKeyPath<MigrationOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { card.options[keyPath: key] }, set: { on in model.update(card.id) { $0.options[keyPath: key] = on } }))
            .toggleStyle(.checkbox)
    }

    @ViewBuilder private var status: some View {
        switch card.status {
        case .needsAccess:
            Label("Needs access", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
        case .scanning:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking…").font(.caption).foregroundStyle(.secondary) }
        case .notFound(let looked):
            VStack(alignment: .leading, spacing: 4) {
                Text("Not found in \(looked). If it's installed, choose \(card.browser.root.displayPath).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Choose Folder…") { Task { await model.grant(card.browser.root) } }.controlSize(.small)
            }
        case .empty:
            Text("Found, but it has no bookmarks or history yet").font(.caption).foregroundStyle(.secondary)
        case .found(let scan):
            Text(Self.describe(scan)).font(.caption).foregroundStyle(.green)
        case .unreadable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if reason.contains("Full Disk Access") {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    static func describe(_ scan: BrowserScan) -> String {
        var parts = ["\(scan.bookmarks.formatted()) bookmarks", "\(scan.history.formatted()) history items"]
        if scan.spaces > 0 { parts.append("\(scan.spaces) spaces") }
        return "Found " + parts.joined(separator: ", ")
    }
}

/// The installed app's icon, or a symbol when it isn't installed.
private struct BrowserIcon: View {
    let browser: SourceBrowser

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: browser.symbol).resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
        }
    }
}

private struct Stat: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value.formatted()).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110)
    }
}
