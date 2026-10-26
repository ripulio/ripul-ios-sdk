#if targetEnvironment(simulator) && (DEBUG || RIPUL_DEVELOPER_TOOLS || RIPUL_DEVELOPER_BUILD)
import Foundation
import UIKit

/// Developer-only local transport. No web view, Clerk session or app login is
/// needed. Only the simulator launcher can supply the single-use launch ticket.
@MainActor
public enum RipulSimulatorTools {
    private static var client: SimulatorToolClient?

    public static func start(registry: RipulToolRegistry) {
        guard client == nil,
              let endpoint = ProcessInfo.processInfo.environment["RIPUL_SIMULATOR_TOOLS_URL"],
              let ticket = ProcessInfo.processInfo.environment["RIPUL_SIMULATOR_TOOLS_TICKET"],
              let url = URL(string: endpoint), url.scheme == "http",
              url.host == "127.0.0.1", url.port != nil,
              url.path == "/simulator-tools", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ticket.count == 64 else { return }
        let bridge = AgentBridge(registry: registry, audience: .developer)
        bridge.registerBuiltInTools(bridge.developerBuiltInTools())
        let connection = SimulatorToolClient(endpoint: url, ticket: ticket, bridge: bridge)
        client = connection
        connection.start()
    }
}

@MainActor
private final class SimulatorToolClient {
    let endpoint: URL
    let bridge: AgentBridge
    private var credential: String
    private let session: URLSession
    private var task: Task<Void, Never>?

    init(endpoint: URL, ticket: String, bridge: AgentBridge) {
        self.endpoint = endpoint
        self.credential = ticket
        self.bridge = bridge
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 35
        self.session = URLSession(configuration: config)
    }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await post("connect", body: [
                    "bundleId": Bundle.main.bundleIdentifier ?? "",
                    "simulatorUdid": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "",
                    "label": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "App",
                    "model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                    "tools": bridge.nativeToolDefinitions,
                ])
                guard let credential = reply["credential"] as? String else { throw URLError(.badServerResponse) }
                self.credential = credential
                if reply["testEndUserTools"] as? Bool == true {
                    _ = bridge.setEndUserTesting(true)
                }
                NSLog("[RipulSimulatorTools] Connected to local host")
            } catch {
                NSLog("[RipulSimulatorTools] Connection refused; relaunch through the simulator launcher")
                return
            }
            while !Task.isCancelled {
                do {
                    // Re-announcing also handles registry changes after startup.
                    let next = try await post("next", body: ["tools": bridge.nativeToolDefinitions])
                    guard let id = next["requestId"] as? String,
                          let name = next["toolName"] as? String else { continue }
                    var response: [String: Any] = ["requestId": id]
                    do {
                        let result = try await bridge.invokeNativeTool(named: name, args: next["args"] as? [String: Any] ?? [:])
                        guard JSONSerialization.isValidJSONObject(["result": result]) else {
                            throw ToolError.invalidArgs("Tool returned a non-JSON result")
                        }
                        response["result"] = result
                        if bridge.isEndUserTestingEnabled, bridge.registry.audience(ofToolNamed: name) == .endUser {
                            response["absorbed"] = true
                        }
                    } catch { response["error"] = error.localizedDescription }
                    // Never re-execute a tool on a lost reply. The host reports
                    // an uncertain outcome instead of replaying a mutation.
                    _ = try await post("reply", body: response)
                } catch {
                    if (error as? URLError)?.code == .userAuthenticationRequired { return }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw URLError(.userAuthenticationRequired) }
        guard http.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }
}
#endif
