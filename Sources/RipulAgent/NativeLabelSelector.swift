import Foundation
import CryptoKit

/// Declarative, host-independent selectors. Row positions and displayed text are
/// deliberately absent: neither identifies a reused view across configurations.
struct NativeLabelSelector: Codable, Hashable {
    struct EnumValue: Codable, Hashable {
        var path: [String]
        var value: String
    }
    struct Row: Codable, Hashable {
        var ownerType: String
        var identifier: String?
        var context: String?
        var enums: [EnumValue] = []
        init(ownerType: String, identifier: String? = nil, context: String? = nil, enums: [EnumValue] = []) {
            self.ownerType = ownerType; self.identifier = identifier; self.context = context; self.enums = enums
        }
        private enum CodingKeys: String, CodingKey { case ownerType, identifier, context, enums }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ownerType = try container.decode(String.self, forKey: .ownerType)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            context = try container.decodeIfPresent(String.self, forKey: .context)
            enums = try container.decodeIfPresent([EnumValue].self, forKey: .enums) ?? []
        }
    }
    var screen: String
    var identifier: String?
    var ownerType: String?
    var property: String?
    var row: Row?

    var id: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var summary: String {
        let anchor = identifier ?? [ownerType, property].compactMap { $0 }.joined(separator: ".")
        let context = row.map { row in
            row.context ?? row.identifier ?? row.enums.map { $0.path.joined(separator: ".") + " = " + $0.value }.joined(separator: ", ")
        }
        return [screen, context, anchor].compactMap { $0 }.joined(separator: " › ")
    }
    var strategy: String {
        if row?.context != nil { return "App-provided row context" }
        if row?.identifier != nil { return "Identified row and label" }
        if row != nil { return "Outlet or identifier with row model context" }
        return identifier != nil ? "Accessibility identifier" : "Screen and stored view property"
    }
    func validate() throws {
        func valid(_ text: String?) -> Bool {
            guard let text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 512
        }
        guard valid(screen),
              (valid(identifier) && ownerType == nil && property == nil) ||
                (identifier == nil && valid(ownerType) && valid(property)) else { throw RipulThemePublishError.invalidDocument }
        if let row {
            let strategies = [row.identifier != nil, row.context != nil, !row.enums.isEmpty].filter { $0 }.count
            guard valid(row.ownerType), strategies == 1,
                  row.identifier == nil || valid(row.identifier), row.context == nil || valid(row.context),
                  row.enums.count <= 16 else { throw RipulThemePublishError.invalidDocument }
            for value in row.enums {
                guard !value.path.isEmpty, value.path.count <= 5,
                      value.path.allSatisfy({ valid($0) }), valid(value.value) else { throw RipulThemePublishError.invalidDocument }
            }
        }
    }
}

struct NativeLabelOverride: Codable, Equatable, Identifiable {
    var selector: NativeLabelSelector
    var text: String
    var id: String { selector.id }
}
