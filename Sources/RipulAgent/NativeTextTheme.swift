import Foundation

/// SDK-owned text bindings. Host theme decoders can ignore this section; the SDK
/// reads it from the complete manifest before handing that manifest to the host.
struct NativeTextTheme: Codable, Equatable {
    var tabBarItemTitles: [String: String] = [:]
    var labels: [NativeLabelOverride] = []
    var tokens: [String: RipulTextReference] = [:]
    var elements: [String: [String: RipulTextReference]] = [:]
    var tabBarItemTokens: [String: String] = [:]

    init(tabBarItemTitles: [String: String] = [:], labels: [NativeLabelOverride] = []) {
        self.tabBarItemTitles = tabBarItemTitles; self.labels = labels
    }
    private enum CodingKeys: String, CodingKey { case tabBarItemTitles, labels, tokens, elements, tabBarItemTokens }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabBarItemTitles = try container.decodeIfPresent([String: String].self, forKey: .tabBarItemTitles) ?? [:]
        labels = try container.decodeIfPresent([NativeLabelOverride].self, forKey: .labels) ?? []
        tokens = try container.decodeIfPresent([String: RipulTextReference].self, forKey: .tokens) ?? [:]
        elements = try container.decodeIfPresent([String: [String: RipulTextReference]].self, forKey: .elements) ?? [:]
        tabBarItemTokens = try container.decodeIfPresent([String: String].self, forKey: .tabBarItemTokens) ?? [:]
        guard labels.count <= 256, Set(labels.map(\.id)).count == labels.count else { throw RipulThemePublishError.invalidDocument }
        for rule in labels { try rule.selector.validate() }
        guard tabBarItemTitles.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Tab title overrides need a stable, nonempty accessibility identifier."))
        }
    }

    static func decode(document: Data) throws -> Self {
        struct Envelope: Decodable { let nativeTextOverrides: NativeTextTheme? }
        return try JSONDecoder().decode(Envelope.self, from: document).nativeTextOverrides ?? Self()
    }

    /// Preserve all host fields and future SDK sections, replacing just this adapter's map.
    func merging(into document: Data, baseline: Data? = nil) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw RipulThemePublishError.invalidDocument
        }
        _ = try Self.decode(document: document)
        var section = json["nativeTextOverrides"] as? [String: Any] ?? [:]
        if !tabBarItemTitles.isEmpty || section["tabBarItemTitles"] != nil {
            section["tabBarItemTitles"] = tabBarItemTitles
        }
        if !labels.isEmpty || section["labels"] != nil {
            section["labels"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(labels))
        }
        let extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        for key in ["tokens", "elements", "tabBarItemTokens"] {
            if let map = extra[key] as? [String: Any], !map.isEmpty || section[key] != nil { section[key] = map }
        }
        // Reset should restore the baseline's absent/empty shape, without hiding
        // unrelated or future fields. Otherwise an undone edit reviews as Empty group.
        if let baseline, let base = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] {
            let original = base["nativeTextOverrides"] as? [String: Any] ?? [:]
            for key in ["tokens", "elements", "tabBarItemTokens", "tabBarItemTitles", "labels"] where original[key] == nil {
                if (section[key] as? [String: Any])?.isEmpty == true || (section[key] as? [Any])?.isEmpty == true {
                    section[key] = nil
                }
            }
            if section.isEmpty { json["nativeTextOverrides"] = base["nativeTextOverrides"] == nil ? nil : section }
        }
        if !section.isEmpty { json["nativeTextOverrides"] = section }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    mutating func setLabel(_ selector: NativeLabelSelector, text: String?, token: String? = nil) {
        labels.removeAll { $0.id == selector.id }
        if let text { labels.append(NativeLabelOverride(selector: selector, text: text, token: token)) }
        labels.sort { $0.id < $1.id }
    }
}
