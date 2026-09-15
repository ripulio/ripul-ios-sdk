import Foundation

struct ToolDefaultAction: Decodable, Equatable {
    let id: String
    let title: String
}

/// Action implementations register independently of lozenge presentation and gestures.
@MainActor
final class ToolDefaultActionRegistry {
    private var handlers: [String: ([String: Any]) -> Void] = [:]
    var features: [String] { handlers.keys.sorted().map { "toolDefaultAction:\($0)" } }
    func register(_ id: String, perform: @escaping ([String: Any]) -> Void) { handlers[id] = perform }
    func perform(_ request: [String: Any]) {
        guard let id = request["actionId"] as? String else { return }
        handlers[id]?(request)
    }
}
