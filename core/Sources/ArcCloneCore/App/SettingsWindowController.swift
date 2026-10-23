import AppKit
import SwiftUI

/// Settings… (⌘,): a toolbar-style preferences window with SwiftUI panes, like the system apps.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(onAgentSettingsChanged: @escaping @MainActor () -> Void) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.pane("General", symbol: "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(Self.pane("Assistant", symbol: "sparkles", AssistantSettingsView(onApply: onAgentSettingsChanged)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("ArcCloneSettings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func pane(_ title: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: 460).fixedSize())
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
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
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @State private var defaultBrowserError: String?

    var body: some View {
        Form {
            Picker("Search engine:", selection: $searchEngine) {
                ForEach(Preferences.SearchEngine.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            TextField("Homepage:", text: $homepage, prompt: Text(Preferences.defaultHomepage))
            LabeledContent("Default browser:") {
                if isDefaultBrowser {
                    Label("ArcClone is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Make ArcClone Default") {
                            DefaultBrowser.makeDefault { error in
                                defaultBrowserError = error?.localizedDescription
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
                    Text(pinStatus ?? "Pinned SPKI SHA-256 hashes. ArcClone refuses the host if its certificate key changes.")
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
                pinStatus = "Couldn't read the certificate: \(error.localizedDescription)"
            }
        }
    }
}
