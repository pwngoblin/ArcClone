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
                    Text("Chrome, Firefox and Safari web extensions (manifest v2 or v3) from an unpacked folder or a .zip. They run in regular windows only.")
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
                                       description: Text("Download an extension's source, unzip it if needed, and add the folder that contains manifest.json."))
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
                                Text([loaded?.version, loaded?.summary].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
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
