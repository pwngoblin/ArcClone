import AppKit
import Security
import SecurityInterface
import SwiftUI
import WebKit

/// What the lock in the address pill reports about the current page.
struct SiteSecurity {
    struct Certificate {
        var subject: String
        var issuer: String?
        var validFrom: Date?
        var validUntil: Date?
    }

    var url: URL
    var host: String
    var isHTTPS: Bool
    /// False when an HTTPS page also loaded HTTP content (mixed content).
    var onlySecureContent: Bool
    var certificate: Certificate?
    var trust: SecTrust?

    enum Level { case secure, mixed, insecure, local }

    var level: Level {
        if url.isFileURL || url.scheme == "about" { return .local }
        guard isHTTPS else { return .insecure }
        return onlySecureContent ? .secure : .mixed
    }

    @MainActor
    init(webView: WKWebView, url: URL) {
        self.url = url
        host = url.host ?? url.absoluteString
        isHTTPS = url.scheme == "https"
        onlySecureContent = webView.hasOnlySecureContent
        trust = webView.serverTrust
        certificate = trust.flatMap(Self.certificate(from:))
    }

    /// Reads the leaf certificate's subject, its issuer and validity window.
    static func certificate(from trust: SecTrust) -> Certificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? "Unknown"
        let issuer = chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : nil
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        let values = SecCertificateCopyValues(leaf, keys, nil) as? [CFString: [CFString: Any]]
        func date(_ oid: CFString) -> Date? {
            (values?[oid]?[kSecPropertyKeyValue] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        return Certificate(subject: subject, issuer: issuer, validFrom: date(kSecOIDX509V1ValidityNotBefore),
                           validUntil: date(kSecOIDX509V1ValidityNotAfter))
    }
}

/// Popover from the lock: connection, certificate, this site's settings and stored data.
struct SiteSecurityView: View {
    let security: SiteSecurity
    let window: WindowModel
    @State private var storedRecords: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let certificate = security.certificate {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Certificate", systemImage: "checkmark.seal").font(.subheadline.weight(.semibold))
                    row("Issued to", certificate.subject)
                    if let issuer = certificate.issuer { row("Issued by", issuer) }
                    if let until = certificate.validUntil {
                        row("Valid until", until.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Show Certificate…") { showCertificate() }.buttonStyle(.link).font(.caption)
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("This site", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                ForEach(siteSettingsSummary, id: \.0) { row($0.0, $0.1) }
                if let storedRecords { row("Cookies & site data", storedRecords == 0 ? "None stored" : "Stored on this Mac") }
            }
            HStack {
                Button("Site Settings…") { window.controller?.showSiteSettings(nil) }
                Spacer()
                Button("Clear Site Data") { clearData() }.disabled(storedRecords == 0)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 330)
        .task { storedRecords = await countRecords() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(security.host).font(.headline).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch security.level {
        case .secure: return "lock.fill"
        case .mixed: return "lock.trianglebadge.exclamationmark.fill"
        case .insecure: return "exclamationmark.triangle.fill"
        case .local: return "doc.fill"
        }
    }

    private var color: Color {
        switch security.level {
        case .secure: return .green
        case .mixed, .insecure: return .orange
        case .local: return .secondary
        }
    }

    private var summary: String {
        switch security.level {
        case .secure: return "Connection is secure. Information you send is private and goes only to this site."
        case .mixed: return "Connection is encrypted, but parts of this page were loaded insecurely and could be seen or changed by others."
        case .insecure: return "Connection is not secure. Don't enter passwords or payment details on this site."
        case .local: return "This is a file on your Mac."
        }
    }

    private var siteSettingsSummary: [(String, String)] {
        guard let settings = window.controller?.factory.siteSettings else { return [] }
        let url = security.url
        var rows: [(String, String)] = [
            ("Camera", settings.permission(\.camera, for: url).title),
            ("Microphone", settings.permission(\.microphone, for: url).title),
            ("JavaScript", settings.allowsJavaScript(for: url) ? "Allowed" : "Blocked"),
            ("Appearance", settings.darkMode(for: url).title),
        ]
        if window.controller?.factory.adBlocker?.isEnabled == true {
            rows.insert(("Ads & trackers", settings.adsAllowed(for: url) ? "Allowed" : "Blocked"), at: 2)
        }
        let zoom = settings.zoom(for: url)
        if abs(zoom - 1) > 0.001 { rows.append(("Zoom", "\(Int(zoom * 100))%")) }
        return rows
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.caption)
    }

    private func matchingRecords() async -> [WKWebsiteDataRecord] {
        guard let store = window.controller?.factory.dataStore, let key = SiteSettings.key(for: security.url) else { return [] }
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records.filter { $0.displayName == key || $0.displayName.hasSuffix(".\(key)") }
    }

    private func countRecords() async -> Int { await matchingRecords().count }

    private func clearData() {
        guard let store = window.controller?.factory.dataStore else { return }
        Task {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: await matchingRecords())
            storedRecords = 0
            window.showToast("Cleared data for \(security.host)")
            window.controller?.tabs.active?.reload()
        }
    }

    /// The system certificate viewer, as a sheet on the browser window.
    private func showCertificate() {
        guard let trust = security.trust, let browser = window.controller?.window else { return }
        SFCertificateTrustPanel.shared()?.beginSheet(for: browser, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                                    trust: trust, message: "Certificate for \(security.host)")
    }
}
