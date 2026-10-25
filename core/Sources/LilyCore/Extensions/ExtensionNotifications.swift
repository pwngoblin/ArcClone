import AppKit
import UserNotifications
import WebKit

/// `chrome.notifications` for extensions, shown through macOS notifications. WebKit's extension
/// runtime has no notifications API, so Lily's worker shim (`injections/extension-worker-compat.js`)
/// sends them over a native-messaging name Lily answers itself (`applicationIdentifier`); no other
/// app or process is involved. Only extensions approved for `notifications` are answered, every
/// request is decoded into a fixed schema with length limits, and macOS asks the user before the
/// first one is shown.
///
/// Clicks, button clicks and dismissals go back to the extension over a port the shim opens while
/// it has notifications showing. When its background is asleep they're kept (up to `maxPending`),
/// the background is started, and the shim collects them once it listens.
@available(macOS 15.4, *)
@MainActor
final class ExtensionNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let applicationIdentifier = "dev.lily.notifications"
    nonisolated static let maxRequestBytes = 16 * 1024
    nonisolated static let maxPending = 50

    struct Request: Decodable, Equatable {
        let action: Action
        let id: String?
        let options: Options?

        enum Action: String, Decodable { case create, update, clear, getAll, getPermissionLevel, events }
    }

    /// The parts of Chrome's `NotificationOptions` macOS can show. Images and progress aren't.
    struct Options: Decodable, Equatable {
        var title: String?
        var message: String?
        var contextMessage: String?
        var buttons: [Button]?
        var silent: Bool?

        struct Button: Decodable, Equatable { let title: String }
    }

    struct Refused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Decodes and bounds a request from an extension. Long text is shortened, not refused, as
    /// Chrome shows it truncated too.
    nonisolated static func decode(_ message: Any) throws -> Request {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= maxRequestBytes,
              var request = try? JSONDecoder().decode(Request.self, from: data) else { throw Refused(reason: "Invalid notification request") }
        if let id = request.id, id.count > 256 || id.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw Refused(reason: "Invalid notification ID")
        }
        if var options = request.options {
            options.title = options.title.map { String($0.prefix(256)) }
            options.message = options.message.map { String($0.prefix(2_000)) }
            options.contextMessage = options.contextMessage.map { String($0.prefix(256)) }
            options.buttons = options.buttons.map { Array($0.prefix(2)).map { Options.Button(title: String($0.title.prefix(64))) } }
            request = Request(action: request.action, id: request.id, options: options)
        }
        return request
    }

    /// Whether the extension was approved for notifications at install.
    var isApproved: (String) -> Bool = { _ in false }
    /// A loaded extension's context, to start its background when an event is waiting.
    var context: (String) -> WKWebExtensionContext? = { _ in nil }

    private var ports: [String: WKWebExtension.MessagePort] = [:]
    private var pending: [String: [[String: Any]]] = [:]
    private var categories: Set<UNNotificationCategory> = []
    /// nil when Lily isn't running as an app bundle (`swift run`, tests): macOS has nowhere to
    /// attribute notifications, so they're reported as denied.
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    // MARK: Requests

    func handle(_ message: Any, from context: WKWebExtensionContext) async throws -> Any? {
        let ext = context.uniqueIdentifier
        guard isApproved(ext) else { throw Refused(reason: "Notifications weren't approved for this extension") }
        let request = try Self.decode(message)
        switch request.action {
        case .events:
            return pending.removeValue(forKey: ext) ?? []
        case .getPermissionLevel:
            guard let center else { return ["level": "denied"] }
            let status = await center.notificationSettings().authorizationStatus
            return ["level": status == .denied ? "denied" : "granted"]
        case .getAll:
            return ["ids": await delivered(ext).map(\.id)]
        case .clear:
            guard let id = request.id, let center else { return ["done": false] }
            let shown = await delivered(ext).contains { $0.id == id }
            center.removeDeliveredNotifications(withIdentifiers: [Self.key(ext, id)])
            await releasePortIfIdle(ext)
            return ["done": shown]
        case .create, .update:
            guard let center else { throw Refused(reason: "Notifications aren't available") }
            let isUpdate = request.action == .update
            let id = request.id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let existing = await delivered(ext).first { $0.id == id }?.content
            if isUpdate && existing == nil { return ["done": false] }
            guard await authorize(center) else { throw Refused(reason: "Notifications are turned off for Lily in System Settings") }
            let content = (existing?.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
            let options = request.options ?? Options()
            if let title = options.title { content.title = title }
            if options.message != nil || options.contextMessage != nil {
                content.body = [options.message, options.contextMessage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
            // Which extension it's from, as Chrome shows.
            content.subtitle = context.webExtension.displayName ?? "Extension"
            content.threadIdentifier = ext
            if let silent = options.silent { content.sound = silent ? nil : .default } else if existing == nil { content.sound = .default }
            if options.buttons != nil || existing == nil { content.categoryIdentifier = category(options.buttons ?? []) }
            try await center.add(UNNotificationRequest(identifier: Self.key(ext, id), content: content, trigger: nil))
            return isUpdate ? ["done": true] : ["id": id]
        }
    }

    /// The shim's port for events, opened while the extension has notifications showing.
    func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) throws {
        let ext = context.uniqueIdentifier
        guard isApproved(ext) else { throw Refused(reason: "Notifications weren't approved for this extension") }
        ports.removeValue(forKey: ext)?.disconnect()
        ports[ext] = port
        port.disconnectHandler = { [weak self, weak port] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.ports[ext], current === port else { return }
                self.ports.removeValue(forKey: ext)
            }
        }
        // The port carries messages only once this call has returned.
        let waiting = pending.removeValue(forKey: ext) ?? []
        guard !waiting.isEmpty else { return }
        Task { @MainActor [weak port] in waiting.forEach { port?.sendMessage($0, completionHandler: nil) } }
    }

    /// The extension was removed or turned off: its notifications go too.
    func removeAll(for ext: String) {
        ports.removeValue(forKey: ext)?.disconnect()
        pending.removeValue(forKey: ext)
        guard let center else { return }
        Task { center.removeDeliveredNotifications(withIdentifiers: await delivered(ext).map { Self.key(ext, $0.id) }) }
    }

    // MARK: Events

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run { self.received(identifier: identifier, action: action) }
    }

    private func received(identifier: String, action: String) {
        guard let (ext, id) = Self.parse(identifier) else { return }
        let event: [String: Any]
        switch action {
        case UNNotificationDefaultActionIdentifier:
            event = ["type": "clicked", "id": id]
            NSApp.activate()
        case UNNotificationDismissActionIdentifier:
            event = ["type": "closed", "id": id, "byUser": true]
        case "button0", "button1":
            event = ["type": "buttonClicked", "id": id, "buttonIndex": action == "button0" ? 0 : 1]
            NSApp.activate()
        default:
            return
        }
        if let port = ports[ext], !port.isDisconnected {
            port.sendMessage(event, completionHandler: nil)
        } else if let context = context(ext) {
            pending[ext, default: []].append(event)
            if pending[ext]!.count > Self.maxPending { pending[ext]!.removeFirst() }
            context.loadBackgroundContent { _ in }
        }
        Task { await releasePortIfIdle(ext) }
    }

    // MARK: Helpers

    nonisolated static func key(_ ext: String, _ id: String) -> String { "ext|\(ext)|\(id)" }

    nonisolated static func parse(_ key: String) -> (ext: String, id: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ext" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    private func delivered(_ ext: String) async -> [(id: String, content: UNNotificationContent)] {
        guard let center else { return [] }
        return await center.deliveredNotifications().compactMap { note in
            guard let (owner, id) = Self.parse(note.request.identifier), owner == ext else { return nil }
            return (id, note.request.content)
        }
    }

    /// Once nothing of the extension's is showing, nothing can come back, so its port (which may
    /// keep its background running) is closed.
    private func releasePortIfIdle(_ ext: String) async {
        if ports[ext] != nil, await delivered(ext).isEmpty { ports.removeValue(forKey: ext)?.disconnect() }
    }

    private func authorize(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        default: return false
        }
    }

    /// A category per set of button titles, each reporting dismissals.
    private func category(_ buttons: [Options.Button]) -> String {
        let titles = buttons.map(\.title)
        let id = "lily.ext." + titles.map { String($0.unicodeScalars.map { String($0.value, radix: 16) }.joined()) }.joined(separator: ".")
        if !categories.contains(where: { $0.identifier == id }) {
            let actions = titles.enumerated().map { UNNotificationAction(identifier: "button\($0.offset)", title: $0.element) }
            categories.insert(UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction]))
            center?.setNotificationCategories(categories)
        }
        return id
    }
}
