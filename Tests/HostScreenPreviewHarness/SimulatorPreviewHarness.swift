import SwiftUI
@testable import RipulAgent

struct SimulatorPreviewHarness: View {
    @StateObject private var state = SimulatorPreviewState()
    @StateObject private var details = ToolCallDetailsStore()
    @State private var taps = 0
    var body: some View {
        VStack {
            Text("Simulator preview over your chat").font(.title2)
            Spacer()
            Button("Open simulator tool") {
                details.receive(["requestId": "simulator-test", "title": "Tool calls", "chatId": "chat", "machineId": "host",
                    "calls": [["id": "call", "toolName": "Bash", "status": "success", "timestamp": 0,
                        "arguments": "{}", "diagnostics": "{}", "rendererName": "Bash:xcrun simctl",
                        "simulatorTargets": [["udid": "08E561AA-A868-4196-AF4A-3501D80DF965"]]]]], opening: true)
            }
            Button("Chat taps: \(taps)") { taps += 1 }.accessibilityIdentifier("SimulatorHarness.chat")
            Button("Open second simulator") {
                state.open(SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17"), machineId: "host", chatId: "chat", automatic: true)
            }
            TextField("Message", text: .constant("")).textFieldStyle(.roundedBorder)
        }.padding()
        .overlay { SimulatorHarnessOverlay(state: state).ignoresSafeArea(.container) }
        .modifier(ToolCallDetailsPresenter(store: details, onDismiss: { _ in }, onViewSimulator: { target, host, chat in
            state.open(target, machineId: host, chatId: chat)
        }))
    }
}

private struct SimulatorHarnessOverlay: UIViewControllerRepresentable {
    let state: SimulatorPreviewState
    func makeUIViewController(context: Context) -> SimulatorPreviewController {
        for key in ["posX", "posY", "w", "h"] { UserDefaults.standard.removeObject(forKey: "ripul.simulatorPreview.\(key)") }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 695)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 695))
            ("9:41\n\nSimulator\n\nYour app preview" as NSString).draw(in: CGRect(x: 30, y: 50, width: 260, height: 550),
                withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white])
        }.jpegData(compressionQuality: 0.6)!.base64EncodedString()
        // Control shows, as in the app, so the panel carries all its buttons.
        state.liveContent = { _, _ in AnyView(Color.green) }
        return SimulatorPreviewController(state: state) { _, _, args, _ in
            let udid = (args.first as? [String: Any])?["udid"] as? String
            return ["success": true, "result": ["name": udid?.hasPrefix("5F0C") == true ? "iPhone Air" : "iPhone 17", "jpegB64": image,
                "appearance": ["cropPresetId": "simulator.display", "cornerRadiusFraction": 62.0 / 440]]]
        }
    }
    func updateUIViewController(_ controller: SimulatorPreviewController, context: Context) {}
}
