import Foundation

/// Old internal links stay hidden in tag pickers; existing metadata is preserved.
enum SessionTagVisibility {
    static func isInternal(_ tag: String) -> Bool { tag.hasPrefix("plan:") }
    static func userTags(_ tags: [String]) -> [String] { tags.filter { !isInternal($0) } }
}
