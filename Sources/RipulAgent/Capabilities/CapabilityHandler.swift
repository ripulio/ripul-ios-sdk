import Foundation

/// Protocol for handling capability method invocations from the web app.
/// Each handler covers one capability type (e.g., "tabs", "scripting", "capture").
@MainActor
public protocol CapabilityHandler {
    /// The capability type identifier (e.g., "tabs", "scripting", "capture").
    var capabilityType: String { get }

    /// Invoke a method with the given arguments.
    /// - Parameters:
    ///   - method: The method name (e.g., "query", "executeCodeString").
    ///   - args: Positional arguments from the web app, JSON-deserialized.
    /// - Returns: A JSON-serializable result.
    func invoke(method: String, args: [Any]) async throws -> Any
}

/// Errors from capability invocations. Error codes match the shared-protocol ErrorCodes.
public enum CapabilityError: LocalizedError {
    case unknownCapability(String)
    case unknownMethod(String, capability: String)
    case invalidArgs(String)
    case executionFailed(String)
    case tabNotFound(Int)

    public var errorDescription: String? {
        switch self {
        case .unknownCapability(let cap):
            return "Unknown capability: \(cap)"
        case .unknownMethod(let method, let cap):
            return "Unknown method '\(method)' on capability '\(cap)'"
        case .invalidArgs(let msg):
            return "Invalid arguments: \(msg)"
        case .executionFailed(let msg):
            return "Execution failed: \(msg)"
        case .tabNotFound(let id):
            return "Tab not found: \(id)"
        }
    }

    public var errorCode: String {
        switch self {
        case .unknownCapability: return "UNKNOWN_CAPABILITY"
        case .unknownMethod: return "UNKNOWN_METHOD"
        case .invalidArgs: return "INVALID_ARGS"
        case .executionFailed, .tabNotFound: return "EXECUTION_FAILED"
        }
    }
}
