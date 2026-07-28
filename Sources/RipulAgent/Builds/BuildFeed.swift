import Foundation

// ---------------------------------------------------------------------------
// OTA build feed — models and reader
// ---------------------------------------------------------------------------
// The wire shapes here are the contract with the Ripul API's
// packages/api/src/builds/types.ts. Keep the CodingKeys in step with it.
//
// A consumer of this SDK already has a Ripul account, so build hosting comes
// with it: publish an IPA to POST /v1/builds and the feed below renders it.
// `RipulBuildFeedSource.staticURL` is the escape hatch for anyone who wants to
// host the feed themselves.
// ---------------------------------------------------------------------------

/// One published build.
public struct RipulBuild: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    /// CFBundleVersion of the build, e.g. "202607281530".
    public let build: String
    /// CFBundleShortVersionString, e.g. "1.0.0".
    public let version: String
    public let notes: String?
    public let gitSha: String?
    public let minOS: String?
    public let bytes: Int
    public let builtAt: String
    /// Signed itms-services manifest URL. Expires — see `urlsExpireAt`.
    public let manifestURL: String
    public let ipaURL: String
    /// `itms-services://…` URL to hand to the system installer.
    public let installURL: String
    /// Unix seconds after which the signed URLs above stop working.
    public let urlsExpireAt: Double

    /// Whether this build's signed install URL is still usable.
    public var installURLIsLive: Bool {
        Date().timeIntervalSince1970 < urlsExpireAt
    }

    /// "13.4 MB"
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Parsed `builtAt`, or nil when the server sent something unexpected.
    public var builtAtDate: Date? {
        ISO8601DateFormatter().date(from: builtAt)
            ?? ISO8601DateFormatter.withFractionalSeconds.date(from: builtAt)
    }
}

/// A named distribution track. Ripul's variants (main, alice) and WAC's
/// flavours (prod, beta, dev) are the same concept.
public struct RipulBuildChannel: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Bundle id the builds in this channel carry. This is what decides whether
    /// installing REPLACES the running app or adds a second icon.
    public let bundleId: String
    /// Newest first.
    public let builds: [RipulBuild]

    public var newestBuild: RipulBuild? { builds.first }
}

public struct RipulBuildFeed: Decodable, Sendable {
    public let app: String
    public let title: String
    public let generatedAt: String
    public let channels: [RipulBuildChannel]

    /// The channel matching a bundle id, if any.
    public func channel(forBundleId bundleId: String) -> RipulBuildChannel? {
        channels.first { $0.bundleId == bundleId }
    }
}

/// Where a host's build feed comes from.
public enum RipulBuildFeedSource: Sendable {
    /// Ripul-hosted: `GET <baseURL>/api/v1/builds?app=<slug>`, authenticated.
    case ripulHosted(app: String)
    /// Self-hosted: a URL returning the same JSON shape. Sent unauthenticated,
    /// so whatever serves it owns its own access control.
    case staticURL(URL)
}

/// Reads a build feed.
public enum RipulBuildFeedClient {

    /// Fetch the feed.
    ///
    /// Returns nil when the request FAILED (network error, non-200) so callers
    /// can tell "unreachable" from an authoritative empty list. The same
    /// distinction the machine registry needs: rendering "no builds published"
    /// because the network blipped is how an empty state becomes a lie.
    public static func fetch(
        source: RipulBuildFeedSource,
        token: String?,
        baseURL: URL = AgentConfiguration.defaultBaseURL
    ) async -> RipulBuildFeed? {
        let url: URL
        switch source {
        case .ripulHosted(let app):
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/v1/builds"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "app", value: app)]
            guard let built = components?.url else { return nil }
            url = built
        case .staticURL(let staticURL):
            url = staticURL
        }

        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // The feed mints short-lived signed URLs, so a cached response hands
        // back install links that may already have expired.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                RipulLog.error("[Builds] feed fetch failed: HTTP \(http.statusCode)")
                return nil
            }
            return try JSONDecoder().decode(RipulBuildFeed.self, from: data)
        } catch {
            RipulLog.error("[Builds] feed fetch failed: \(error)")
            return nil
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
