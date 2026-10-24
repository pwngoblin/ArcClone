import Foundation

/// Where a message came from. Page messages can only arrive through the isolated
/// injection content world, so web content itself never reaches these handlers.
public enum IPCSource: Sendable, Equatable {
    case page(tabID: UUID, isMainFrame: Bool, url: URL?)

    /// Route permission classes. Only injected page scripts message native code today; the browser
    /// chrome is native SwiftUI and calls Swift directly.
    public enum Kind: Sendable, Hashable {
        case page
    }

    public var kind: Kind { .page }

    public var tabID: UUID? {
        if case .page(let id, _, _) = self { return id }
        return nil
    }
}

public struct IPCContext: Sendable {
    public let source: IPCSource
    public let messageID: String
    public let kind: IPCEnvelope.Kind
}

/// Type-keyed dispatcher with per-route source permissions.
@MainActor
public final class IPCRouter {
    public typealias Handler = @MainActor (IPCContext, JSONValue) async throws -> JSONValue

    private struct Route {
        let allowed: Set<IPCSource.Kind>
        let handler: Handler
    }

    /// Page events are small (titles, selections ≤ 20k chars); anything larger is refused unread.
    public static let maxMessageBytes = 256 * 1024
    /// Per-tab token bucket: bursts up to `burst` messages, refilled at `perSecond`. A page that
    /// churns its title or selection can't make our scripts flood native code.
    static let burst = 60.0
    static let perSecond = 20.0
    private var buckets: [UUID: (tokens: Double, at: Date)] = [:]

    private var routes: [String: Route] = [:]
    public var onUnhandledEvent: (@MainActor (IPCContext, String, JSONValue) -> Void)?

    public init() {}

    public func on(_ type: String, from allowed: Set<IPCSource.Kind>, _ handler: @escaping Handler) {
        precondition(routes[type] == nil, "Duplicate IPC route \(type)")
        routes[type] = Route(allowed: allowed, handler: handler)
    }

    public var registeredTypes: [String] { routes.keys.sorted() }

    private func take(for tab: UUID, now: Date = Date()) -> Bool {
        var bucket = buckets[tab] ?? (Self.burst, now)
        bucket.tokens = min(Self.burst, bucket.tokens + now.timeIntervalSince(bucket.at) * Self.perSecond)
        bucket.at = now
        guard bucket.tokens >= 1 else { buckets[tab] = bucket; return false }
        bucket.tokens -= 1
        buckets[tab] = bucket
        return true
    }

    /// Called when a tab closes so its bucket doesn't linger.
    public func forget(tab: UUID) { buckets[tab] = nil }

    /// Entry point used by `ScriptMessageBridge`: raw WebKit body in, reply JSON string out.
    public func dispatch(rawBody: Any, source: IPCSource) async -> String {
        guard let body = rawBody as? String else {
            return IPCReply.failure(.malformed("Message body must be a JSON string")).jsonString()
        }
        guard body.utf8.count <= Self.maxMessageBytes else {
            return IPCReply.failure(.malformed("Message exceeds \(Self.maxMessageBytes) bytes")).jsonString()
        }
        if let tab = source.tabID, !take(for: tab) {
            return IPCReply.failure(IPCError("rate_limited", "Too many messages")).jsonString()
        }
        let envelope: IPCEnvelope
        do {
            envelope = try JSONDecoder().decode(IPCEnvelope.self, from: Data(body.utf8))
        } catch {
            return IPCReply.failure(.malformed("Invalid envelope")).jsonString()
        }
        return await dispatch(envelope, source: source).jsonString()
    }

    public func dispatch(_ envelope: IPCEnvelope, source: IPCSource) async -> IPCReply {
        guard envelope.v == IPCEnvelope.protocolVersion else {
            return .failure(.malformed("Unsupported protocol version \(envelope.v)"))
        }
        let context = IPCContext(source: source, messageID: envelope.id, kind: envelope.kind)
        let payload = envelope.payload ?? .null

        guard let route = routes[envelope.type] else {
            if envelope.kind == .event, let fallback = onUnhandledEvent {
                fallback(context, envelope.type, payload)
                return .success(.null)
            }
            Log.ipc.debug("Unknown IPC type \(envelope.type, privacy: .public)")
            return .failure(.unknownType(envelope.type))
        }
        guard route.allowed.contains(source.kind) else {
            Log.ipc.error("Blocked \(envelope.type, privacy: .public) from \(String(describing: source.kind), privacy: .public)")
            return .failure(.forbidden(envelope.type))
        }
        do {
            return .success(try await route.handler(context, payload))
        } catch let error as IPCError {
            return .failure(error)
        } catch {
            Log.ipc.error("Handler \(envelope.type, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
            return .failure(.internal(Sanitize.errorMessage(error)))
        }
    }
}
