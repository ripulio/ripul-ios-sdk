import Foundation

/// Minimal JSON value tree used for the open `props` bag on CMS blocks and
/// for query result rows. The web keeps `CmsBlock.props` as
/// `Record<string, unknown>` so the wire format stays open to any future
/// block type — this is the Swift mirror of that decision.
public enum CmsJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CmsJSON])
    case array([CmsJSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let o = try? container.decode([String: CmsJSON].self) {
            self = .object(o)
        } else if let a = try? container.decode([CmsJSON].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
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

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: CmsJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Human-readable rendering of any scalar — what a bound text prop shows.
    /// Whole numbers drop the trailing `.0` so `42` doesn't render as `42.0`.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        case .object, .array: return ""
        }
    }
}

public extension Dictionary where Key == String, Value == CmsJSON {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func object(_ key: String) -> [String: CmsJSON]? { self[key]?.objectValue }
}
