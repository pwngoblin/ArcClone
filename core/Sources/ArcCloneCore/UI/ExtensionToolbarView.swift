import SwiftUI

/// The toolbar's Extensions popover: each running extension as a row with its icon and action
/// badge (click to run its action and show its popup), then Add and Manage. On macOS before 15.4
/// extensions run their page scripts only, which the popover says.
struct ExtensionToolbarView: View {
    @Bindable var library: ExtensionLibrary
    /// `ExtensionManager` on macOS 15.4+, nil in compatibility mode.
    let runtime: AnyObject?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Extensions").font(.headline)
                Spacer()
                if runtime == nil && !library.ready.isEmpty {
                    Label("Page scripts only", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Popups and background features need macOS 15.4 or later.")
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 2)
            if library.ready.isEmpty {
                Label(library.installed.isEmpty ? "No extensions installed yet" : "Your extensions are turned off",
                      systemImage: "puzzlepiece.extension")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 6)
            } else {
                ForEach(library.ready) { entry in
                    ExtensionActionRow(entry: entry, runtime: runtime, close: close)
                }
            }
            Divider().padding(.vertical, 2)
            Button {
                close()
                Task { await library.install(presentingIn: NSApp.keyWindow) }
            } label: { Label("Add Extension…", systemImage: "plus.circle") }
                .buttonStyle(ToolbarRowStyle())
            Button {
                close()
                (NSApp.delegate as? AppDelegate)?.showExtensionsSettings(nil)
            } label: { Label("Manage Extensions…", systemImage: "gearshape") }
                .buttonStyle(ToolbarRowStyle())
        }
        .padding(10)
        .frame(width: 280)
    }
}

private struct ExtensionActionRow: View {
    let entry: ExtensionLibrary.Entry
    let runtime: AnyObject?
    let close: () -> Void

    var body: some View {
        Button {
            close()
            if #available(macOS 15.4, *) { (runtime as? ExtensionManager)?.performAction(entry.id) }
        } label: {
            HStack(spacing: 10) {
                icon.frame(width: 18, height: 18)
                Text(entry.name).lineLimit(1)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background(.tint, in: Capsule())
                }
            }
        }
        .buttonStyle(ToolbarRowStyle())
        .disabled(runtime == nil)
        .help(runtime == nil ? "Runs on matching pages automatically" : "Open \(entry.name)")
    }

    @ViewBuilder private var icon: some View {
        if let image = actionIcon ?? entry.icon {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private var actionIcon: NSImage? {
        if #available(macOS 15.4, *) { return (runtime as? ExtensionManager)?.actionIcon(entry.id) }
        return nil
    }

    private var badge: String? {
        if #available(macOS 15.4, *) { return (runtime as? ExtensionManager)?.badge(entry.id) }
        return nil
    }
}

/// A full-width row that highlights on hover, like a menu item.
private struct ToolbarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 6).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}
