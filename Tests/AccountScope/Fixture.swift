import Foundation

/// Stand-in for the RipulAgent symbol `RipulAccountScopedCache.swift` uses, so
/// the production file compiles on its own. Only the methods it touches.
public protocol RipulSessionCache: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

public final class MemoryCache: RipulSessionCache {
    public var values: [String: Any] = [:]
    public init() {}
    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
    public func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

/// A Clerk-shaped JWT for `subject` (unsigned; only the payload is read).
func jwt(_ subject: String) -> String {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url("{\"alg\":\"RS256\"}")).\(b64url("{\"sub\":\"\(subject)\",\"exp\":1}")).sig"
}
