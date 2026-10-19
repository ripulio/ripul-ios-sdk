import Foundation

/// Routes capability requests to registered handlers.
/// This is the Swift equivalent of the extension's capabilities/index.ts.
@MainActor
public final class CapabilityRouter {
    private var handlers: [String: CapabilityHandler] = [:]

    public init() {}

    /// Register a capability handler.
    public func register(_ handler: CapabilityHandler) {
        handlers[handler.capabilityType] = handler
    }

    /// Invoke a capability method.
    public func invoke(capability: String, method: String, args: [Any]) async throws -> Any {
        let privacyEpoch = SecureInputProtection.epoch
        try SecureInputProtection.check()
        guard let handler = handlers[capability] else {
            throw CapabilityError.unknownCapability(capability)
        }
        do {
            let result = try await handler.invoke(method: method, args: args)
            try SecureInputProtection.check(since: privacyEpoch)
            return result
        } catch {
            try SecureInputProtection.check(since: privacyEpoch)
            throw error
        }
    }

    /// List all registered capability type identifiers.
    public var availableCapabilities: [String] {
        Array(handlers.keys)
    }

    /// Check if a capability is registered.
    public func hasCapability(_ type: String) -> Bool {
        handlers[type] != nil
    }
}
