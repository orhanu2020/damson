import Foundation

/// A small, Sendable JSON value type used for tool schemas, tool inputs and provider payloads.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Builds a JSONValue from the output of JSONSerialization.
    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]:
            var dict: [String: JSONValue] = [:]
            for (k, v) in o { dict[k] = JSONValue(any: v) }
            self = .object(dict)
        default:
            self = .null
        }
    }

    /// Converts to a Foundation object suitable for JSONSerialization.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o):
            var dict: [String: Any] = [:]
            for (k, v) in o { dict[k] = v.any }
            return dict
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public func string(_ key: String) -> String? {
        return self[key]?.stringValue
    }

    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    public func jsonString(pretty: Bool = false) -> String {
        let obj = self.any
        if JSONSerialization.isValidJSONObject(obj) {
            let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: options),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        switch self {
        case .string(let s): return "\"" + s + "\""
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return "null"
        }
    }

    /// Convenience for building an object schema: properties are (name, type, description).
    public static func schema(_ properties: [(String, String, String)], required: [String] = []) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (name, type, description) in properties {
            props[name] = .object(["type": .string(type), "description": .string(description)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { JSONValue.string($0) }),
        ])
    }
}
