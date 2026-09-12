import Foundation

/// Text and references are different values: literal wording can never accidentally
/// become a token name. The object representation is shared by tokens and assignments.
public enum RipulTextReference: Codable, Equatable, Hashable {
    case text(String)
    case token(String)

    private enum CodingKeys: String, CodingKey { case text, token }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.text) != values.contains(.token) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Choose text or a text token."))
        }
        if values.contains(.text) { self = .text(try values.decode(String.self, forKey: .text)) }
        else { self = .token(try values.decode(String.self, forKey: .token)) }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try values.encode(text, forKey: .text)
        case .token(let token): try values.encode(token, forKey: .token)
        }
    }
}

enum TextReferenceError: LocalizedError {
    case unknown(String), cycle, data, name
    var errorDescription: String? {
        switch self {
        case .unknown(let name): return "The text token ‘\(name)’ does not exist."
        case .cycle: return "These text tokens would refer back to each other."
        case .data: return "This value comes from app data. Edit it using the app’s controls."
        case .name: return "Choose a unique, nonempty text token name."
        }
    }
}
