import Foundation

/// Fetches the relay machine registry (the set of host Macs the signed-in
/// developer can pair with). Extracted from the app's `loadRemoteMachines`.
enum MachineDirectory {
    private struct MachinesResponse: Decodable {
        let machines: [RemoteMachine]
        let count: Int
    }

    /// Fetch the relay machine registry.
    ///
    /// Returns nil when the request FAILED (network error, non-200) so callers
    /// can distinguish "unreachable" from an authoritative empty list —
    /// onboarding and empty-state UI must never treat a failed fetch as
    /// "brand-new account".
    static func fetch(token: String, baseURL: URL = AgentConfiguration.defaultBaseURL) async -> [RemoteMachine]? {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/relay/machines"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            return try JSONDecoder().decode(MachinesResponse.self, from: data).machines
        } catch {
            return nil
        }
    }
}
