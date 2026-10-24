import SwiftUI

/// Settings → Extensions: add, enable, configure and remove web extensions.
@available(macOS 15.4, *)
struct ExtensionsSettingsView: View {
    @Bindable var manager: ExtensionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Extensions").font(.headline)
                    Text("Chrome, Firefox and Safari web extensions from a folder, .zip or .crx. Each is reviewed before it's added, then pinned: this exact copy runs and never updates on its own. They run in regular windows only.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await manager.install(presentingIn: NSApp.keyWindow) } } label: { Label("Add Extension…", systemImage: "plus") }
            }
            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if manager.installed.isEmpty {
                ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension",
                                       description: Text("Add an extension's folder (with manifest.json), .zip or .crx. You'll see what it can do and what the review found before it's added."))
                    .frame(height: 180)
            } else {
                List {
                    ForEach(manager.installed) { record in
                        let loaded = manager.loaded.first { $0.id == record.id }
                        HStack(spacing: 10) {
                            Group {
                                if let icon = loaded?.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary) }
                            }
                            .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(loaded?.name ?? "Extension").font(.system(size: 13, weight: .medium))
                                Text([loaded?.version, manager.pinnedHash(record.id).map { "pinned \($0)" }, loaded?.summary]
                                        .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if loaded?.context.optionsPageURL != nil {
                                Button("Options") { manager.openOptions(record.id) }.controlSize(.small)
                            }
                            Toggle("", isOn: Binding(get: { record.enabled }, set: { manager.setEnabled(record.id, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            Button(role: .destructive) { manager.remove(record.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.bordered)
                .frame(height: 220)
            }
        }
        .padding(20)
    }
}

/// The toolbar's Extensions popover: each loaded extension (click to run its action), add, manage.
@available(macOS 15.4, *)
struct ExtensionsPopoverView: View {
    @Bindable var manager: ExtensionManager
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extensions").font(.headline).padding(.horizontal, 6)
            if manager.loaded.isEmpty {
                Text(manager.installed.isEmpty ? "No extensions installed yet." : "Your extensions are turned off.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 4)
            } else {
                ForEach(manager.loaded) { loaded in
                    Button {
                        close()
                        manager.performAction(loaded.id)
                    } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let icon = loaded.context.webExtension.actionIcon(for: CGSize(width: 18, height: 18)) ?? loaded.icon {
                                    Image(nsImage: icon).resizable()
                                } else {
                                    Image(systemName: "puzzlepiece.extension").resizable().scaledToFit()
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text(loaded.name).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 6).frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button {
                close()
                Task { await manager.install(presentingIn: NSApp.keyWindow) }
            } label: { Label("Add Extension…", systemImage: "plus") }
                .buttonStyle(.plain).padding(.horizontal, 6)
            Button {
                close()
                (NSApp.delegate as? AppDelegate)?.showExtensionsSettings(nil)
            } label: { Label("Manage Extensions…", systemImage: "gearshape") }
                .buttonStyle(.plain).padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 260)
    }
}
