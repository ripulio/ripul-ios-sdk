import SwiftUI
import WebKit
@testable import RipulAgent

@MainActor private final class AnchorHarnessEvents: ObservableObject { var dismiss: ((String) -> Void)? }

struct AnchoredToolStripHarness: View {
    @StateObject private var events = AnchorHarnessEvents()
    @StateObject private var strip = NativeToolStripStore()
    @StateObject private var details = ToolCallDetailsStore()
    var body: some View {
        AnchoredToolStripWebHarness(strip: strip, details: details, events: events)
            .modifier(ToolCallDetailsPresenter(store: details, onDismiss: { events.dismiss?($0) }))
    }
}

private struct AnchoredToolStripWebHarness: UIViewControllerRepresentable {
    let strip: NativeToolStripStore
    let details: ToolCallDetailsStore
    let events: AnchorHarnessEvents
    func makeUIViewController(context: Context) -> AnchoredToolStripTestController {
        AnchoredToolStripTestController(strip: strip, details: details, events: events)
    }
    func updateUIViewController(_ controller: AnchoredToolStripTestController, context: Context) {}
}

private final class AnchoredToolStripTestController: UIViewController, WKScriptMessageHandler {
    let strip: NativeToolStripStore
    let details: ToolCallDetailsStore
    let events: AnchorHarnessEvents
    var web: FullBleedWebView!
    var anchor: NativeToolStripAnchorController!
    var rows: NativeToolStripRowsController!
    let allRows = ProcessInfo.processInfo.arguments.contains("--all-tool-rows-ui-tests")
    let status = UILabel()
    var reports = 0
    var defaultActionCount = 0
    var lastGeometry: [String: Any] = [:]
    init(strip: NativeToolStripStore, details: ToolCallDetailsStore, events: AnchorHarnessEvents) {
        self.strip = strip; self.details = details; self.events = events
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "agentBridge")
        web = FullBleedWebView(frame: .zero, configuration: config)
        web.scrollView.bounces = false
        anchor = NativeToolStripAnchorController(webView: web, store: strip)
        rows = NativeToolStripRowsController(webView: web, presenter: strip, send: { [weak self] in self?.sendToWeb($0) })
        web.toolStripAccessibilityElements = { [weak self] in (self?.rows.accessibilityElements ?? []) + (self?.anchor.accessibilityElements ?? []) }
        web.toolStripHitTest = { [weak self] point, event in self?.rows.hitTest(point, event: event) ?? self?.anchor.hitTest(point, event: event) }
        strip.present { [weak self] in self?.sendToWeb($0) }
        events.dismiss = { [weak self] id in
            guard let data = try? JSONSerialization.data(withJSONObject: ["type": "agent-framework:toolCallDetails:dismissed", "requestId": id]), let json = String(data: data, encoding: .utf8) else { return }
            self?.web.evaluateJavaScript("window.postMessage(\(json), '*')")
        }
        let buttons = UIStackView(); buttons.distribution = .fillEqually
        let actions: [(String, Selector)] = allRows ? [("Rows", #selector(loadRows)), ("Scroll", #selector(scroll)), ("Append", #selector(appendRow)), ("Measure", #selector(measureRows)), ("Hide", #selector(hideRows)), ("Show", #selector(showRows)), ("End", #selector(end)), ("History", #selector(history)), ("Top", #selector(top))] : [("Load", #selector(loadTools)), ("Scroll", #selector(scroll)), ("Grow", #selector(grow)), ("Measure", #selector(measure)), ("Hide", #selector(hideRows)), ("Show", #selector(showRows)), ("End", #selector(end)), ("Short", #selector(short))]
        let visibleActions = ProcessInfo.processInfo.arguments.contains("--tool-default-actions-ui-tests")
            ? [("Simulator", #selector(loadSimulator)), ("Scroll", #selector(scroll)), ("Measure", #selector(measure))] : actions
        for (title, action) in visibleActions {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 13)
            button.addTarget(self, action: action, for: .touchUpInside); buttons.addArrangedSubview(button)
        }
        status.text = "Loading"; status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.numberOfLines = 3; status.accessibilityIdentifier = "AnchorHarness.status"
        let stack = UIStackView(arrangedSubviews: [buttons, status, web]); stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 44), status.heightAnchor.constraint(equalToConstant: 45)])
        let bundle = try! String(contentsOf: Bundle.main.url(forResource: "tool-strip-anchor-fixture", withExtension: "js")!, encoding: .utf8)
        let html = #"<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;padding:0;overflow:hidden}</style><div id="root"></div><script>window.nativeAnchorHarness=true;window.nativeAnchorDark=__ANCHOR_DARK__;window.fixtureNativeBridge={supportsUIFeature:f=>['nativeToolStrip','nativeToolStripAnchor','toolCallDetails','toolDefaultAction:simulator.preview',__ROWS_FEATURE__].includes(f),sendToNative:m=>window.webkit.messageHandlers.agentBridge.postMessage(m)};</script><script>"# + bundle.replacingOccurrences(of: "</script", with: "<\\/script") + #"</script><script>setTimeout(()=>window.webkit.messageHandlers.agentBridge.postMessage({type:'ready'}),500)</script>"#
        web.loadHTMLString(html.replacingOccurrences(of: "__ROWS_FEATURE__", with: allRows ? "'nativeToolStripRows'" : "''").replacingOccurrences(of: "__ANCHOR_DARK__", with: ProcessInfo.processInfo.arguments.contains("--dark-appearance") ? "true" : "false"), baseURL: URL(string: "https://tool-groups.test/cli-turn?virtual=1"))
    }
    private func sendToWeb(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.postMessage(\(json), '*')")
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "agent-framework:toolDefaultAction:perform":
            defaultActionCount += 1
            status.text = "Default actions: \(defaultActionCount)"
        case "ready": status.text = "Ready"
        case "agent-framework:toolStrip:update": strip.receive(body)
        case "agent-framework:toolStrip:clear": strip.clear(ownerId: body["ownerId"] as? String)
        case "agent-framework:toolStrip:anchor": reports += 1; lastGeometry = body; anchor.receive(body)
        case "agent-framework:toolStripRow:update": rows.receive(body)
        case "agent-framework:toolStripRow:anchor": reports += 1; rows.receiveAnchor(body)
        case "agent-framework:toolStripRow:clear": rows.clear(ownerId: body["ownerId"] as? String, groupId: body["groupId"] as? String)
        case "agent-framework:toolCallDetails:open": details.receive(body, opening: true)
        case "agent-framework:toolCallDetails:update": details.receive(body, opening: false)
        default: break
        }
    }
    @objc func loadRows() { seedRows(count: 3) }
    @objc func history() { seedRows(count: 120) }
    @objc func top() { web.evaluateJavaScript(#"document.querySelector('[data-ui="V2ChatScroller.scroll"]').scrollTop = 0"#) }
    private func seedRows(count: Int) {
        web.evaluateJavaScript(#"""
        window.makeAnchorRow = n => [
          ...['Read','Bash'].map((tool,i)=>({id:`multi-${n}-${i}`,correlationId:`multi-${n}-${i}`,timestamp:n*3+i,method:'llmRequest.toolStatus',providerNames:['fixture'],originalMessage:{},processedMessage:{payload:{toolSelected:tool,toolArgs:tool==='Bash'?{command:'python3 -c "print(42)"'}:{path:`file-${n}.md`},status:'success'}}})),
          {id:`separator-${n}`,correlationId:`separator-${n}`,timestamp:n*3+2,method:'userMessage',providerNames:['fixture'],originalMessage:{},processedMessage:{payload:{data:{question:`Message after tool row ${n}`}}}}
        ];
        window.anchorRowCount = __COUNT__;
        window.rowMessages = Array.from({length:window.anchorRowCount},(_,n)=>window.makeAnchorRow(n)).flat();
        window.setFixtureMessages(window.rowMessages);
        """#.replacingOccurrences(of: "__COUNT__", with: String(count)))
    }
    @objc func appendRow() {
        web.evaluateJavaScript("window.rowMessages=[...window.rowMessages,...window.makeAnchorRow(window.anchorRowCount++)];window.setFixtureMessages(window.rowMessages)")
    }
    @objc func measureRows() {
        web.evaluateJavaScript(#"(()=>{const s=document.querySelector('[data-ui="V2ChatScroller.scroll"]');return {opacity:s?Number(getComputedStyle(s).opacity):0,width:s?.getBoundingClientRect().width??0,anchors:[...document.querySelectorAll('[data-ui="NativeToolStrip.anchor"]')].map(a=>({id:a.dataset.toolGroup,y:a.getBoundingClientRect().top,fallback:!!a.querySelector('[data-ui="V2MessageRow.groupHeader"]')}))}})()"#) { [weak self] value, error in
            guard let self, let values = value as? [String: Any] else { return }
            let width = (values["width"] as? NSNumber)?.doubleValue ?? 0
            let scale = width > 0 ? self.web.bounds.width / width : 1
            let anchors = values["anchors"] as? [[String: Any]] ?? []
            let frames = self.rows.framesInWebView
            let errors = anchors.compactMap { item -> Double? in
                guard let id = item["id"] as? String, let frame = frames[id], let y = item["y"] as? NSNumber else { return nil }
                return abs(frame.minY - y.doubleValue * scale)
            }
            let fallback = anchors.filter { item in frames[item["id"] as? String ?? ""] != nil && item["fallback"] as? Bool == true }.count
            self.status.text = String(format: "error=%.1f native=%d dom=%d states=%d fallback=%d reports=%d opacity=%.1f", errors.max() ?? 0, self.rows.attachmentCount, anchors.count, self.rows.rowCount, fallback, self.reports, (values["opacity"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
    @objc func loadTools() { seedMessages(short: false) }
    @objc func loadSimulator() {
        seedMessages(short: false)
        web.evaluateJavaScript(#"window.anchorMessages=window.anchorMessages.map(m=>m.id==='call-2'?{...m,processedMessage:{payload:{toolSelected:'Bash',toolArgs:{command:'xcrun simctl io 08E561AA-A868-4196-AF4A-3501D80DF965 screenshot /tmp/test.png'},status:'success'}}}:m);window.setFixtureMessages(window.anchorMessages)"#)
    }
    private func seedMessages(short: Bool) {
        web.evaluateJavaScript(#"""
        window.anchorMessages = Array.from({length:30},(_,i)=>({id:'text-'+i,correlationId:'text-'+i,timestamp:i,method:'userMessage',providerNames:['fixture'],originalMessage:{},processedMessage:{payload:{data:{question:'Chat message '+i+' before the native toolbar'}}}}));
        for(const [id,tool] of [['call-1','Read'],['call-2','Bash']]) window.anchorMessages.push({id,correlationId:id,timestamp:100,method:'llmRequest.toolStatus',providerNames:['fixture'],originalMessage:{},processedMessage:{payload:{toolSelected:tool,toolArgs:tool==='Bash'?{command:'python3 -c "print(42)"'}:{path:'README.md'},status:'success'}}});
        for(let i=0;i<4;i++)window.anchorMessages.push({id:'after-'+i,correlationId:'after-'+i,timestamp:200+i,method:'userMessage',providerNames:['fixture'],originalMessage:{},processedMessage:{payload:{data:{question:'Chat message below the native toolbar '+i}}}});
        window.setFixtureMessages(__ANCHOR_MESSAGES__);
        """#.replacingOccurrences(of: "__ANCHOR_MESSAGES__", with: short ? "window.anchorMessages.filter(m=>m.id.startsWith('call-'))" : "window.anchorMessages"))
    }
    @objc func scroll() { web.evaluateJavaScript(#"document.querySelector('[data-ui="V2ChatScroller.scroll"]').scrollTop -= 60"#) }
    @objc func grow() { web.evaluateJavaScript(#"window.anchorMessages = window.anchorMessages.map(m=>m.id==='text-29'?{...m,processedMessage:{payload:{data:{question:'Extra streamed content '.repeat(70)}}}}:m);window.setFixtureMessages(window.anchorMessages)"#) }
    @objc func hideRows() { web.evaluateJavaScript("window.setFixtureHideRows(true)"); status.text = "Hidden" }
    @objc func short() { seedMessages(short: true) }
    @objc func showRows() { web.evaluateJavaScript("window.setFixtureHideRows(false)") }
    @objc func end() { web.evaluateJavaScript(#"(()=>{const s=document.querySelector('[data-ui="V2ChatScroller.scroll"]');s.scrollTop=s.scrollHeight})()"#) }
    @objc func measure() {
        // The viewport spans the web view's known physical width. This provides
        // an independent conversion for pre-26.4 WebKit's unzoomed DOM rects.
        web.evaluateJavaScript(#"(()=>{const a=document.querySelector('[data-ui="NativeToolStrip.anchor"]'),s=document.querySelector('[data-ui="V2ChatScroller.scroll"]');return {y:a?.getBoundingClientRect().top??-999,width:s?.getBoundingClientRect().width??0,scroll:s?.scrollTop??0}})()"#) { [weak self] value, error in
            guard let self else { return }
            let values = value as? [String: Any] ?? [:]
            let domWidth = (values["width"] as? NSNumber)?.doubleValue ?? 0
            let domY = ((values["y"] as? NSNumber)?.doubleValue ?? -999) * (domWidth > 0 ? self.web.bounds.width / domWidth : 1)
            let nativeY = self.anchor.frameInWebView?.minY ?? -999
            let geometryY = (self.lastGeometry["anchor"] as? [String: Any])?["y"] as? NSNumber
            self.status.text = String(format: "error=%.1f native=%.1f dom=%.1f anchor=%.1f height=%.1f\nreports=%d placements=%d scroll=%.1f", nativeY-domY, nativeY, domY, geometryY?.doubleValue ?? -999, (self.lastGeometry["contentHeight"] as? NSNumber)?.doubleValue ?? 0, self.reports, self.anchor.placementCount, (values["scroll"] as? NSNumber)?.doubleValue ?? 0)
            if !self.strip.anchored {
                self.status.text! += "\nExpected: \(self.lastGeometry.filter { ["anchor", "viewport", "contentHeight", "viewportWidth"].contains($0.key) })"
                func dump(_ view: UIView, _ depth: Int = 0) {
                    if let s = view as? UIScrollView { self.status.text! += "\n\(type(of:s)): \(s.convert(s.bounds, to:self.web)), bounds=\(s.bounds), content=\(s.contentSize), offset=\(s.contentOffset)" }
                    for child in view.subviews { dump(child, depth+1) }
                }; dump(self.web)
            }
        }
    }
}
