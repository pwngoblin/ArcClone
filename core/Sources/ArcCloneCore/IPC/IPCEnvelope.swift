import Foundation

/// Wire format shared by injections (`injections/modules/runtime.js`) and the chrome UI
/// (`ui/src/lib/bridge.js`). Every message is a JSON string so WebKit's bridging of
/// JS values never has to be trusted.
public struct IPCEnvelope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case request
        case event
    }

    public static let protocolVersion = 1

    public var v: Int
    public var id: String
    public var kind: Kind
    public var type: String
    public var payload: JSONValue?

    public init(id: String = UUID().uuidString, kind: Kind, type: String, payload: JSONValue? = nil) {
        self.v = Self.protocolVersion
        self.id = id
        self.kind = kind
        self.type = type
        self.payload = payload
    }
}

public struct IPCError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }

    public static func invalidParams(_ message: String) -> IPCError { IPCError("invalid_params", message) }
    public static func notFound(_ message: String) -> IPCError { IPCError("not_found", message) }
    public static func forbidden(_ type: String) -> IPCError { IPCError("forbidden", "Source may not call '\(type)'") }
    public static func unknownType(_ type: String) -> IPCError { IPCError("unknown_type", "No handler for '\(type)'") }
    public static func malformed(_ message: String) -> IPCError { IPCError("malformed", message) }
    public static func unavailable(_ message: String) -> IPCError { IPCError("unavailable", message) }
    public static func `internal`(_ message: String) -> IPCError { IPCError("internal", message) }
}

public struct IPCReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var result: JSONValue?
    public var error: IPCError?

    public static func success(_ result: JSONValue) -> IPCReply { IPCReply(ok: true, result: result, error: nil) }
    public static func failure(_ error: IPCError) -> IPCReply { IPCReply(ok: false, result: nil, error: error) }

    public func jsonString() -> String {
        (try? JSONValue.from(self).jsonString()) ?? #"{"ok":false,"error":{"code":"internal","message":"encode failed"}}"#
    }
}

/// Helpers for reading typed params out of a payload.
public extension JSONValue {
    func required(_ key: String) throws -> JSONValue {
        guard let v = self[key], !v.isNull else { throw IPCError.invalidParams("Missing '\(key)'") }
        return v
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try required(key).string else { throw IPCError.invalidParams("'\(key)' must be a string") }
        return s
    }

    func requiredUUID(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try requiredString(key)) else { throw IPCError.invalidParams("'\(key)' must be a UUID") }
        return id
    }
}
