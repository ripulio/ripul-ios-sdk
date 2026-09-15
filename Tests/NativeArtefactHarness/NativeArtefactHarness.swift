import SwiftUI
import WebKit

@testable import RipulAgent

@main struct NativeArtefactHarnessApp: App {
  var body: some Scene {
    WindowGroup {
      HarnessView().preferredColorScheme(
        ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)
    }
  }
}
private struct HarnessView: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> HarnessController { HarnessController() }
  func updateUIViewController(_ controller: HarnessController, context: Context) {}
}
private final class HarnessController: UIViewController, WKScriptMessageHandler {
  var web: FullBleedWebView!
  var embeds: NativeEmbedController!
  let status = UILabel()
  override func viewDidLoad() {
    super.viewDidLoad()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(self, name: "agentBridge")
    web = FullBleedWebView(frame: .zero, configuration: configuration)
    embeds = NativeEmbedController(
      webView: web, registry: .standard(), send: { [weak self] message in self?.send(message) })
    web.toolStripAccessibilityElements = { [weak self] in self?.embeds.accessibilityElements ?? [] }
    web.toolStripHitTest = { [weak self] point, event in self?.embeds.hitTest(point, event: event) }
    let buttons = UIStackView()
    buttons.distribution = .fillEqually
    for (title, action) in [
      ("Calculator", #selector(calculator)), ("Checklist", #selector(checklist)),
      ("Hide", #selector(hide)), ("Show", #selector(showContent)), ("Probe", #selector(probe)),
    ] {
      let b = UIButton(type: .system)
      b.setTitle(title, for: .normal)
      b.titleLabel?.font = .systemFont(ofSize: 12)
      b.addTarget(self, action: action, for: .touchUpInside)
      buttons.addArrangedSubview(b)
    }
    status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    status.numberOfLines = 3
    status.accessibilityIdentifier = "NativeArtefactHarness.status"
    status.text = "Opening"
    let stack = UIStackView(arrangedSubviews: [buttons, status, web])
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      buttons.heightAnchor.constraint(equalToConstant: 38),
      status.heightAnchor.constraint(equalToConstant: 40),
    ])
    view.backgroundColor = .systemBackground
    web.load(URLRequest(url: URL(string: "http://127.0.0.1:18983")!))
  }
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any] else { return }
    embeds.receive(body)
  }
  func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8)
    else { return }
    web.evaluateJavaScript("window.dispatchEvent(new MessageEvent('message',{data:\(json)}))")
  }
  @objc func calculator() { web.evaluateJavaScript("fixtureSetCase('calculator')") }
  @objc func checklist() { web.evaluateJavaScript("fixtureSetCase('checklist')") }
  @objc func hide() { web.evaluateJavaScript("fixtureSetMounted(false)") }
  @objc func showContent() { web.evaluateJavaScript("fixtureSetMounted(true)") }
  @objc func probe() {
    web.evaluateJavaScript(
      "JSON.stringify({visible:document.querySelector('[data-ui=\"NativeEmbed.slot\"]')?.dataset.nativeVisible,rect:(()=>{const r=document.querySelector('[data-ui=\"NativeEmbed.slot\"]')?.getBoundingClientRect();return r?{x:r.x,y:r.y,width:r.width,height:r.height}:null})(),sent:fixtureSent.length})"
    ) { [weak self] value, error in
      guard let self else { return }
      self.status.text =
        "attached=\(self.embeds.attachmentCount) "
        + (value as? String ?? error?.localizedDescription ?? "nil")
    }
  }
}
