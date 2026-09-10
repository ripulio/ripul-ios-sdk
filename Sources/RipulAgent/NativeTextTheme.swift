import Foundation

/// SDK-owned text bindings. Host theme decoders can ignore this section; the SDK
/// reads it from the complete manifest before handing that manifest to the host.
struct NativeTextTheme: Codable, Equatable {
    var tabBarItemTitles: [String: String] = [:]

    init(tabBarItemTitles: [String: String] = [:]) { self.tabBarItemTitles = tabBarItemTitles }
    private enum CodingKeys: String, CodingKey { case tabBarItemTitles }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabBarItemTitles = try container.decodeIfPresent([String: String].self, forKey: .tabBarItemTitles) ?? [:]
        guard tabBarItemTitles.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Tab title overrides need a stable, nonempty accessibility identifier."))
        }
    }

    static func decode(document: Data) throws -> Self {
        struct Envelope: Decodable { let nativeTextOverrides: NativeTextTheme? }
        return try JSONDecoder().decode(Envelope.self, from: document).nativeTextOverrides ?? Self()
    }

    /// Preserve all host fields and future SDK sections, replacing just this adapter's map.
    func merging(into document: Data) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw RipulThemePublishError.invalidDocument
        }
        _ = try Self.decode(document: document)
        var section = json["nativeTextOverrides"] as? [String: Any] ?? [:]
        if !tabBarItemTitles.isEmpty || section["tabBarItemTitles"] != nil {
            section["tabBarItemTitles"] = tabBarItemTitles
        }
        if !section.isEmpty { json["nativeTextOverrides"] = section }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
}
