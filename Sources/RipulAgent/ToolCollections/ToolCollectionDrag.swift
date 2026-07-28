import Foundation

/// The payload carried when a tool is dragged between collections.
///
/// A drop has to know where the tool came FROM, not just what it is: moving
/// `get_events` from "Calendar" to "Scheduling" removes it from one collection
/// and adds it to the other, and the drop site only knows the destination.
///
/// Transferred as a JSON *string* rather than a custom `Transferable` with a
/// bespoke `UTType`. An exported UTType is supposed to be declared in the
/// host app's Info.plist, and the SDK cannot add keys to a consumer's plist —
/// an undeclared type risks a drag that silently does nothing on device, which
/// a compile can't catch. A string payload always works.
struct RipulToolDragItem: Codable {
    let toolName: String
    /// Collection the tool is being dragged out of; nil when dragged from the
    /// ungrouped list.
    let sourceCollectionId: String?

    /// Marks the payload as ours, so text dropped from elsewhere is ignored
    /// rather than parsed into a nonsense edit.
    private static let marker = "ripul.toolDrag.v1"
    private let kind: String

    init(toolName: String, sourceCollectionId: String?) {
        self.toolName = toolName
        self.sourceCollectionId = sourceCollectionId
        self.kind = Self.marker
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Nil for anything that isn't one of our payloads.
    static func decode(_ raw: String) -> RipulToolDragItem? {
        guard let data = raw.data(using: .utf8),
              let item = try? JSONDecoder().decode(RipulToolDragItem.self, from: data),
              item.kind == marker else {
            return nil
        }
        return item
    }
}
