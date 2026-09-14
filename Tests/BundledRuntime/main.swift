import Foundation
import CryptoKit
import Network

@main struct RuntimeChecks {
    @MainActor static func main() async throws {
        let oldMode = UserDefaults.standard.object(forKey: "ripul.standalone.enabled")
        defer { UserDefaults.standard.set(oldMode, forKey: "ripul.standalone.enabled") }
        UserDefaults.standard.set(true, forKey: "ripul.standalone.enabled")
        StandaloneNetworkPolicy.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ripul-runtime-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Fixture.bundle/Contents/Resources/StandaloneRuntime")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>io.ripul.runtime.fixture</string></dict></plist>"
        try Data(plist.utf8).write(to: root.appendingPathComponent("Fixture.bundle/Contents/Info.plist"))
        let html = Data("<!doctype html><title>Bundled fixture</title>".utf8)
        try html.write(to: resources.appendingPathComponent("popup.html"))
        try Data("private".utf8).write(to: resources.appendingPathComponent("unlisted.txt"))
        let manifest: [String: Any] = ["version": 1, "protocolVersion": 1, "entry": "popup.html", "files": ["popup.html": ["sha256": SHA256.hash(data: html).map { String(format: "%02x", $0) }.joined(), "bytes": html.count]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: resources.appendingPathComponent("runtime-manifest.json"))
        let runtime = BundledAgentRuntime()
        let url = try await runtime.start(bundle: Bundle(url: root.appendingPathComponent("Fixture.bundle"))!)
        var count = 0
        func check(_ ok: Bool, _ label: String) {
            precondition(ok, label); count += 1; print("PASS \(label)")
        }
        check(url.host == "127.0.0.1" && url.port != nil, "loopback origin")
        check(try await runtime.start() == url, "idempotent concurrent-owner startup")
        func request(_ path: String, method: String = "GET", host: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: path, relativeTo: url)!)
            request.httpMethod = method
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let (data, response) = try await request("/popup")
        check(response.statusCode == 200 && data == html, "inventoried entry delivered")
        check(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("connect-src 'self'") == true, "external web requests excluded by CSP")
        check(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff", "no MIME sniffing")
        let (head, headResponse) = try await request("/popup", method: "HEAD")
        check(head.isEmpty && headResponse.statusCode == 200, "HEAD without body")
        for path in ["/unlisted.txt", "/runtime-manifest.json", "/%2e%2e/Info.plist", "/%5c..%5cInfo.plist", "/host/evaluate"] {
            check(try await request(path).1.statusCode == 404, "unavailable route \(path)")
        }
        check(try await request("/popup", method: "POST").1.statusCode == 404, "no mutation method")
        check(try await request("/popup", host: "attacker.example").1.statusCode == 404, "reject DNS rebinding host")
        try Data("tampered".utf8).write(to: resources.appendingPathComponent("popup.html"))
        check(try await request("/popup").1.statusCode == 404, "reject damaged bundle asset")
        let external = URL(string: "https://standalone-denied.invalid/test")!
        check(!StandaloneNetworkPolicy.denies(external, standalone: false), "hosted mode keeps its existing network access")
        check(StandaloneNetworkPolicy.denies(URL(string: "https://127.0.0.1.attacker.example")!, standalone: true), "loopback lookalike cannot bypass native policy")
        do {
            _ = try await URLSession.shared.data(from: external)
            preconditionFailure("External native request escaped standalone policy")
        } catch let error as NSError {
            check(error.domain == NSURLErrorDomain && error.code == NSURLErrorNotConnectedToInternet && error.localizedDescription.contains("standalone"), "external native HTTP rejected before connecting")
        }
        print("\(count) bundled runtime checks passed")
    }
}
