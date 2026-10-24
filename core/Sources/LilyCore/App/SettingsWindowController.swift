import AppKit
import SwiftUI

/// Settings… (⌘,): a toolbar-style preferences window with SwiftUI panes, like the system apps.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(siteSettings: SiteSettings, adBlocker: AdBlocker, extensionLibrary: ExtensionLibrary?, extensionRuntime: AnyObject?, clearBrowsingData: @escaping @MainActor () -> Void,
         onAgentSettingsChanged: @escaping @MainActor () -> Void) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.pane("General", symbol: "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(Self.pane("Tabs", symbol: "square.on.square", TabsSettingsView()))
        tabs.addTabViewItem(Self.pane("Appearance", symbol: "paintpalette", AppearanceSettingsView()))
        tabs.addTabViewItem(Self.pane("Websites", symbol: "globe", WebsitesSettingsView(settings: siteSettings)))
        tabs.addTabViewItem(Self.pane("Privacy", symbol: "hand.raised", PrivacySettingsView(adBlocker: adBlocker, clearBrowsingData: clearBrowsingData)))
        if let extensionLibrary {
            tabs.addTabViewItem(Self.pane("Extensions", symbol: "puzzlepiece.extension", ExtensionsSettingsView(library: extensionLibrary, runtime: extensionRuntime)))
        }
        tabs.addTabViewItem(Self.pane("Assistant", symbol: "sparkles", AssistantSettingsView(onApply: onAgentSettingsChanged)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("LilySettings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func pane(_ title: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: 520).fixedSize().appAccent())
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func select(pane label: String) {
        guard let tabs = contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label == label }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    func present() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(Preferences.Key.searchEngine) private var searchEngine = Preferences.SearchEngine.google.rawValue
    @AppStorage(Preferences.Key.homepage) private var homepage = Preferences.defaultHomepage
    @AppStorage(Preferences.Key.restoreSession) private var restoreSession = true
    @AppStorage(Preferences.Key.haptics) private var haptics = true
    @AppStorage(Preferences.Key.webDeveloperFeatures) private var webDeveloper = false
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @State private var defaultBrowserError: String?

    var body: some View {
        Form {
            Picker("Search engine:", selection: $searchEngine) {
                ForEach(Preferences.SearchEngine.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            TextField("Homepage:", text: $homepage, prompt: Text(Preferences.defaultHomepage))
            Toggle("Haptic feedback on the trackpad", isOn: $haptics)
            Toggle("Show features for web developers", isOn: $webDeveloper)
                .onChange(of: webDeveloper) { (NSApp.delegate as? AppDelegate)?.webDeveloperFeaturesChanged() }
            LabeledContent("") {
                Text("Adds Inspect Element to the page menu, Develop → Show Web Inspector (⌥⌘I), and lets Safari's Develop menu inspect Lily's pages. Inspected pages can read and change what's on them, so leave it off unless you need it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("On launch, open:", selection: $restoreSession) {
                Text("Tabs from last time").tag(true)
                Text("The homepage").tag(false)
            }
            LabeledContent("Default browser:") {
                if isDefaultBrowser {
                    Label("Lily is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Make Lily Default") {
                            DefaultBrowser.makeDefault { error in
                                defaultBrowserError = error.map(Sanitize.errorMessage)
                                isDefaultBrowser = DefaultBrowser.isDefault
                            }
                        }
                        .disabled(!DefaultBrowser.isAvailable)
                        if !DefaultBrowser.isAvailable {
                            Text("Available in the packaged app.").font(.caption).foregroundStyle(.secondary)
                        } else if let defaultBrowserError {
                            Text(defaultBrowserError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefaultBrowser = DefaultBrowser.isDefault
        }
    }
}

struct TabsSettingsView: View {
    @AppStorage(Preferences.Key.newTabsNextToCurrent) private var nextToCurrent = true
    @AppStorage(Preferences.Key.sleepTabsAfter) private var sleepAfter = TabSleeper.defaultMinutes
    @AppStorage(Preferences.Key.pauseIdlePanesAfter) private var pausePanesAfter = PaneFreezer.defaultMinutes

    var body: some View {
        Form {
            Picker("Open new tabs:", selection: $nextToCurrent) {
                Text("Next to the current tab").tag(true)
                Text("At the end of the list").tag(false)
            }
            .pickerStyle(.radioGroup)
            Picker("Sleep unused tabs after:", selection: $sleepAfter) {
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("Never").tag(0)
            }
            .frame(width: 260)
            LabeledContent("") {
                Text("Sleeping tabs release their memory and use no CPU; they reload where you left off when you open them. Tabs playing media or using the camera stay awake, and Low Power Mode sleeps tabs after 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Pause idle split panes after:", selection: $pausePanesAfter) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("Never").tag(0)
            }
            .frame(width: 260)
            LabeledContent("") {
                Text("A pane of a split you haven't clicked into shows a still picture while its page is paused: no scripts, animations or rendering. Click or scroll it to resume. Panes playing media, loading, or with Link Scrolling on keep running.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Shortcuts:") {
                Text("⌘T new tab · ⌘W close · ⇧⌘T reopen · ⌘D pin · ⌘1–⌘9 jump · ⌃Tab cycle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceStyle.Key.appAppearance) private var mode = AppearanceStyle.Mode.system.rawValue
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent
    @AppStorage(AppearanceStyle.Key.sidebarTint) private var tint = AppearanceStyle.defaultAccent
    @AppStorage(AppearanceStyle.Key.tintStrength) private var strength = 0.12
    @AppStorage(AppearanceStyle.Key.grain) private var grain = 0.0

    var body: some View {
        Form {
            Picker("Appearance:", selection: $mode) {
                ForEach(AppearanceStyle.Mode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .onChange(of: mode) { _, _ in AppearanceStyle.applyAppAppearance() }

            LabeledContent("Accent color:") { swatches($accent) }
            LabeledContent("Sidebar color:") { swatches($tint) }
            LabeledContent("Color strength:") {
                Slider(value: $strength, in: 0...0.5) { EmptyView() } minimumValueLabel: { Image(systemName: "circle") } maximumValueLabel: { Image(systemName: "circle.fill") }
                    .frame(width: 260)
            }
            LabeledContent("Grain:") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $grain, in: 0...0.6) { EmptyView() } minimumValueLabel: { Text("Smooth").font(.caption) } maximumValueLabel: { Text("Paper").font(.caption) }
                        .frame(width: 260)
                    Text("Adds a subtle paper-like texture to the sidebar.").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Preview:") {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(.background)
                    SidebarBackground().clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(hex: accent).opacity(0.22)).frame(height: 22)
                            .overlay(alignment: .leading) { Text("Active tab").font(.caption).padding(.leading, 8) }
                        Text("Another tab").font(.caption).padding(.leading, 8)
                    }
                    .padding(10)
                }
                .frame(width: 260, height: 80)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }
            LabeledContent("") {
                Button("Restore Defaults") {
                    accent = AppearanceStyle.defaultAccent; tint = AppearanceStyle.defaultAccent; strength = 0.12; grain = 0
                    mode = AppearanceStyle.Mode.system.rawValue; AppearanceStyle.applyAppAppearance()
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private func swatches(_ value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(AppearanceStyle.presets, id: \.self) { hex in
                Circle().fill(Color(hex: hex)).frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.primary.opacity(value.wrappedValue == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                    .onTapGesture { value.wrappedValue = hex }
                    .help(hex)
            }
            ColorPicker("", selection: Binding(get: { Color(hex: value.wrappedValue) }, set: { value.wrappedValue = $0.hexString }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }
}

struct WebsitesSettingsView: View {
    @Bindable var settings: SiteSettings
    @AppStorage(Preferences.Key.defaultZoom) private var defaultZoom = 1.0
    @AppStorage(Preferences.Key.defaultDarkMode) private var defaultDarkMode = SiteSettings.DarkMode.standard.rawValue

    var body: some View {
        Form {
            Picker("Default zoom:", selection: $defaultZoom) {
                ForEach([0.75, 0.85, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }
            .frame(width: 220)
            Picker("Website appearance:", selection: $defaultDarkMode) {
                ForEach(SiteSettings.DarkMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .frame(width: 260)
            LabeledContent("") {
                Text("“Force Dark” uses a site's own dark theme when it has one and inverts it otherwise.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Customized sites:") {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.sites.isEmpty {
                        Text("None yet. Use the toolbar's Site Settings button on any site.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach(settings.sites.keys.sorted(), id: \.self) { host in
                                HStack {
                                    Text(host)
                                    Spacer()
                                    Text(summary(settings.sites[host] ?? .init())).font(.caption).foregroundStyle(.secondary)
                                    Button { settings.reset(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(width: 330, height: 150)
                        .listStyle(.bordered)
                        Button("Remove All") { settings.removeAll() }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private func summary(_ site: SiteSettings.Site) -> String {
        var parts: [String] = []
        if let zoom = site.zoom { parts.append("\(Int(zoom * 100))%") }
        if let dark = site.darkMode { parts.append(dark.title) }
        if site.javaScript == false { parts.append("No JS") }
        if let camera = site.camera { parts.append("Camera: \(camera.title)") }
        if let mic = site.microphone { parts.append("Mic: \(mic.title)") }
        return parts.joined(separator: " · ")
    }
}

struct PrivacySettingsView: View {
    @Bindable var adBlocker: AdBlocker
    let clearBrowsingData: @MainActor () -> Void
    @AppStorage(Preferences.Key.adBlock) private var blockAds = true
    @AppStorage(Preferences.Key.httpsFirst) private var httpsFirst = true
    @AppStorage(Preferences.Key.historyRetentionDays) private var retention = History.defaultRetentionDays
    @AppStorage(Preferences.Key.clearHistoryOnQuit) private var clearHistoryOnQuit = false
    @AppStorage(Preferences.Key.clearWebsiteDataOnQuit) private var clearDataOnQuit = false

    var body: some View {
        Form {
            Toggle("Block ads and trackers", isOn: $blockAds)
                .onChange(of: blockAds) { _, _ in adBlocker.settingsChanged() }
            LabeledContent("Filter lists:") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FilterLists.all) { list in
                        Toggle(isOn: Binding(get: { adBlocker.isListEnabled(list.id) },
                                             set: { adBlocker.setList(list.id, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(list.name)
                                Text(list.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Downloaded from each list's maintainer and updated weekly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!blockAds)
            }
            LabeledContent("") {
                HStack {
                    if adBlocker.isUpdating { ProgressView().controlSize(.small) }
                    Text(adBlocker.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if blockAds && !adBlocker.enabledLists.isEmpty {
                        Button("Update Now") { Task { await adBlocker.updateFilterLists() } }
                            .controlSize(.small).disabled(adBlocker.isUpdating)
                    }
                }
            }
            Toggle("Upgrade connections to HTTPS (HTTPS-First)", isOn: $httpsFirst)
            Picker("Keep history:", selection: $retention) {
                Text("One day").tag(1)
                Text("One week").tag(7)
                Text("One month").tag(30)
                Text("Three months").tag(90)
                Text("One year").tag(365)
                Text("Forever").tag(0)
            }
            .frame(width: 220)
            Toggle("Clear history when Lily quits", isOn: $clearHistoryOnQuit)
            Toggle("Clear cookies and website data when Lily quits", isOn: $clearDataOnQuit)
            LabeledContent("") {
                Text("Website data (cookies, storage, caches) is written by WebKit unencrypted inside Lily's container. Clearing it on quit signs you out of websites each time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("") {
                Button("Clear Browsing Data…", action: clearBrowsingData)
            }
            LabeledContent("Protected:") {
                Text("Your session, history and site settings are encrypted on disk with a key in your Keychain. Private windows leave none of them behind.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}

struct AssistantSettingsView: View {
    @AppStorage(Preferences.Key.ollamaHost) private var ollamaHost = ""
    @AppStorage(Preferences.Key.agentModel) private var agentModel = ""
    @AppStorage(Preferences.Key.ollamaPins) private var pins = ""
    @State private var pinStatus: String?
    let onApply: @MainActor () -> Void

    var body: some View {
        Form {
            TextField("Ollama host:", text: $ollamaHost, prompt: Text("http://127.0.0.1:11434"))
            TextField("Model:", text: $agentModel, prompt: Text("First installed"))
            LabeledContent("Certificate pins:") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $pins, prompt: Text("Optional, for a remote HTTPS host"))
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        Button("Pin Current Certificate") { pinCurrentCertificate() }
                            .disabled(!AssistantConfiguration.normalizedHost(ollamaHost).absoluteString.hasPrefix("https://"))
                        if !pins.isEmpty { Button("Clear") { pins = ""; pinStatus = nil } }
                    }
                    Text(pinStatus ?? "Pinned SPKI SHA-256 hashes. Lily refuses the host if its certificate key changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Apply", action: onApply)
                    Text("The assistant talks to Ollama on your Mac (or a host you trust). Remote hosts must use HTTPS.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    /// Trust on first use, by explicit user action: records the key of the host's current,
    /// system-validated certificate plus its issuer's key as a backup pin.
    private func pinCurrentCertificate() {
        let url = AssistantConfiguration.normalizedHost(ollamaHost)
        pinStatus = "Checking \(url.host ?? "")…"
        Task {
            do {
                let found = try await CertificatePinning.currentPins(for: url)
                pins = found.prefix(2).joined(separator: ", ")
                pinStatus = "Pinned \(min(found.count, 2)) key(s) for \(url.host ?? ""). Click Apply."
            } catch {
                pinStatus = "Couldn't read the certificate: \(Sanitize.errorMessage(error))"
            }
        }
    }
}
