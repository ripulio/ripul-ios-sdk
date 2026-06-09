import SwiftUI

struct AutocompleteCategory: Codable, Identifiable {
    let id: String
    let label: String
    let description: String
    let webIcon: String
    let sfSymbol: String
}

private struct AutocompleteCategoriesFile: Codable {
    let categories: [AutocompleteCategory]
}

enum AutocompleteConstants {
    static let categories: [AutocompleteCategory] = {
        let url = Bundle.main.url(forResource: "autocomplete-categories", withExtension: "json")
            ?? Bundle.allBundles.lazy.compactMap { $0.url(forResource: "autocomplete-categories", withExtension: "json") }.first
        guard let url,
              let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AutocompleteCategoriesFile.self, from: raw)
        else {
            return []
        }
        return decoded.categories
    }()

    static func category(for id: String) -> AutocompleteCategory? {
        return categories.first(where: { $0.id == id })
    }
}
