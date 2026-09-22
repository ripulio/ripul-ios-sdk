import Foundation
import CryptoKit

/// Shared disk format for View Explorer, publication review and launch restoration.
struct RipulThemeDraft: Codable {
    let text: String
    let baseline: Data
    let etag: String?
    var data: Data { Data(text.utf8) }

    static func location(for url: URL?) -> URL {
        let key = SHA256.hash(data: Data((url?.absoluteString ?? "local-theme").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ripul/ThemeDrafts/" + key + ".json")
    }
}
