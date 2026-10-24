import SwiftUI
import WebKit

/// The site-settings popover from the toolbar: zoom, appearance, JavaScript, camera and
/// microphone for the current site, plus clearing its data.
struct SiteSettingsView: View {
    @Bindable var settings: SiteSettings
    let url: URL
    let isPrivate: Bool
    let controller: BrowserWindowController?

    private var site: SiteSettings.Site { settings.site(for: url) }
    private var host: String { SiteSettings.key(for: url) ?? url.host ?? url.absoluteString }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FaviconView(url: url.faviconGuess, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host).font(.headline).lineLimit(1)
                    Label(url.scheme == "https" ? "Connection is secure" : "Connection is not secure",
                          systemImage: url.scheme == "https" ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(url.scheme == "https" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Zoom").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button { controller?.zoomOut(nil) } label: { Image(systemName: "minus") }
                        Text("\(Int((controller?.tabs.active?.webView.pageZoom ?? 1) * 100))%")
                            .monospacedDigit().frame(minWidth: 44)
                        Button { controller?.zoomIn(nil) } label: { Image(systemName: "plus") }
                        Button("Reset") { controller?.actualSize(nil) }.buttonStyle(.link)
                    }
                    .controlSize(.small)
                }
                GridRow {
                    Text("Appearance").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { settings.darkMode(for: url) }, set: { controller?.setDarkMode($0) })) {
                        ForEach(SiteSettings.DarkMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                }
                GridRow {
                    Text("Ads & trackers").foregroundStyle(.secondary)
                    Toggle("Block", isOn: Binding(get: { !settings.adsAllowed(for: url) }, set: { block in
                        guard !isPrivate else { return }
                        settings.update(url) { $0.adsAllowed = block ? nil : true }
                        controller?.tabs.active?.reload()
                    }))
                    .disabled(isPrivate)
                }
                GridRow {
                    Text("JavaScript").foregroundStyle(.secondary)
                    Toggle("Allow", isOn: Binding(get: { settings.allowsJavaScript(for: url) }, set: { allow in
                        guard !isPrivate else { return }
                        settings.update(url) { $0.javaScript = allow ? nil : false }
                        controller?.tabs.active?.reload()
                    }))
                    .disabled(isPrivate)
                }
                GridRow {
                    Text("Camera").foregroundStyle(.secondary)
                    permissionPicker(\.camera)
                }
                GridRow {
                    Text("Microphone").foregroundStyle(.secondary)
                    permissionPicker(\.microphone)
                }
            }

            Divider()
            HStack {
                Button("Clear Data for This Site…") { clearSiteData() }
                Spacer()
                Button("Reset") { settings.reset(host); controller?.tabs.active?.siteSettingsDidChange() }
                    .disabled(site.isEmpty || isPrivate)
            }
            .controlSize(.small)
            if isPrivate {
                Text("Changes in a private window last until it closes and aren't saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func permissionPicker(_ keyPath: WritableKeyPath<SiteSettings.Site, SiteSettings.Permission?>) -> some View {
        Picker("", selection: Binding(get: { settings.permission(keyPath, for: url) }, set: { value in
            guard !isPrivate else { return }
            settings.update(url) { $0[keyPath: keyPath] = value == .ask ? nil : value }
        })) {
            ForEach(SiteSettings.Permission.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().frame(width: 120).disabled(isPrivate)
    }

    /// Removes cookies, storage and caches for this site only (signs you out of it).
    private func clearSiteData() {
        // The active tab's store: a space with Separate logins keeps this site's data apart.
        guard let store = controller.map({ $0.factory.dataStore(forSpace: $0.tabs.active?.spaceID) }) else { return }
        let target = host
        Task {
            let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            let matching = records.filter { $0.displayName == target || $0.displayName.hasSuffix(".\(target)") }
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
            controller?.model.showToast("Cleared data for \(target)")
            controller?.tabs.active?.reload()
        }
    }
}
