import SwiftUI

/// Settings → Extensions: add, enable, configure and remove web extensions.
struct ExtensionsSettingsView: View {
    @Bindable var library: ExtensionLibrary
    /// `ExtensionManager` on macOS 15.4+, nil in compatibility mode.
    let runtime: AnyObject?
    @State private var storeLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Extensions").font(.headline)
                    Text("Chrome, Firefox and Safari web extensions from a folder, .zip, .crx or a Chrome Web Store link. Each is reviewed before it's added, then pinned: this exact copy runs and never updates on its own. They run in regular windows only."
                         + (runtime == nil ? " On this version of macOS only their page scripts run; popups and background features need macOS 15.4 or later." : ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await library.install(presentingIn: NSApp.keyWindow) } } label: { Label("Add Extension…", systemImage: "plus") }
            }
            HStack(spacing: 8) {
                TextField("Chrome Web Store link or extension ID", text: $storeLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addFromStore)
                    .disabled(library.storeStatus != nil)
                if let status = library.storeStatus {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Button("Add from Store", action: addFromStore)
                    .disabled(library.storeStatus != nil || ChromeWebStore.extensionID(from: storeLink) == nil)
                    .help("Downloads the extension from Google, checks its signature, then reviews it before it's added")
            }
            if let error = library.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if library.installed.isEmpty {
                ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension",
                                       description: Text("Add an extension's folder (with manifest.json), .zip or .crx. You'll see what it can do and what the review found before it's added."))
                    .frame(height: 180)
            } else {
                List {
                    ForEach(library.installed) { record in
                        HStack(spacing: 10) {
                            Group {
                                if let icon = library.icon(record.id) { Image(nsImage: icon).resizable() } else { Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary) }
                            }
                            .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(library.displayName(record.id)).font(.system(size: 13, weight: .medium))
                                Text([library.displayVersion(record.id), library.pinnedHash(record.id).map { "pinned \($0)" },
                                      record.storeID.map { _ in "Chrome Web Store" }, library.summary(record.id)]
                                        .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if hasOptions(record.id) {
                                Button("Options") { openOptions(record.id) }.controlSize(.small)
                            }
                            Toggle("", isOn: Binding(get: { record.enabled }, set: { library.setEnabled(record.id, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            Button(role: .destructive) { library.remove(record.id) } label: { Image(systemName: "trash") }
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

    private func addFromStore() {
        guard ChromeWebStore.extensionID(from: storeLink) != nil, library.storeStatus == nil else { return }
        let input = storeLink
        Task {
            await library.install(fromStore: input)
            if library.lastError == nil { storeLink = "" }
        }
    }

    private func hasOptions(_ id: String) -> Bool {
        if #available(macOS 15.4, *) { return (runtime as? ExtensionManager)?.hasOptions(id) ?? false }
        return false
    }

    private func openOptions(_ id: String) {
        if #available(macOS 15.4, *) { (runtime as? ExtensionManager)?.openOptions(id) }
    }
}
