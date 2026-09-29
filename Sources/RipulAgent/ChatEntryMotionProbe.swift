#if os(iOS) && DEBUG
import UIKit
import WebKit
import QuartzCore

/// Where the chat actually is on screen, frame by frame, for a few seconds
/// after a chat entry. The web page cannot see this: the entry "nod" was
/// measured with no scrollTop, row or viewport change inside the page, so any
/// visible motion is native — the web view's rendered position, WebKit's own
/// scroll layer for the chat, or the native tool lozenges placed over it.
///
/// Samples presentation layers (what is on screen, animations included), logs
/// one `[ENTRYMOTION]` summary plus the changed frames. Debug builds only.
@MainActor
final class ChatEntryMotionProbe {
    static let shared = ChatEntryMotionProbe()

    /// One WebKit scroll layer (one per CSS overflow element, hidden chats
    /// included). `id` is stable per native view; `vis` is its effective
    /// on-screen opacity, so the showing chat can be told from hidden ones.
    private struct Layer: Equatable {
        var id: String, vis: Int, y: Int, h: Int, content: Int, offset: Int, shown: Int
    }
    private struct Sample: Equatable {
        var webY: Int, webH: Int, layers: [Layer], lozenges: [Int]
    }

    private var link: CADisplayLink?
    private weak var bridge: AgentBridge?
    private var label = ""
    private var startedAt: CFTimeInterval = 0
    private var samples: [(ms: Int, sample: Sample)] = []

    private init() {}

    func start(bridge: AgentBridge, label: String, duration: TimeInterval = 3) {
        link?.invalidate()
        self.bridge = bridge
        self.label = label
        startedAt = CACurrentMediaTime()
        samples = []
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func sample() {
        guard let bridge, let webView = bridge.probeWebView, let window = webView.window else { return }
        let windowLayer = window.layer.presentation() ?? window.layer
        func screenRect(_ view: UIView) -> CGRect {
            let layer = view.layer.presentation() ?? view.layer
            return layer.convert(layer.bounds, to: windowLayer)
        }
        func opacity(_ view: UIView) -> Float {
            var value: Float = 1
            var current: UIView? = view
            while let v = current, v !== window {
                value *= (v.layer.presentation() ?? v.layer).opacity
                if v.isHidden { return 0 }
                current = v.superview
            }
            return value
        }
        var layers: [Layer] = []
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll !== webView.scrollView,
               scroll.bounds.height > 200, scroll.contentSize.height > scroll.bounds.height + 1 {
                let rect = screenRect(scroll)
                layers.append(Layer(id: String(UInt(bitPattern: ObjectIdentifier(scroll).hashValue) % 10000),
                                    vis: Int((opacity(scroll) * 100).rounded()), y: Int(rect.minY.rounded()),
                                    h: Int(rect.height.rounded()), content: Int(scroll.contentSize.height.rounded()),
                                    offset: Int(scroll.contentOffset.y.rounded()),
                                    shown: Int(((scroll.layer.presentation() ?? scroll.layer).bounds.origin.y).rounded())))
            }
            for child in view.subviews { visit(child) }
        }
        visit(webView.scrollView)
        let web = screenRect(webView)
        let lozenges = bridge.probeToolStripScreenMinYs.suffix(4)
        let next = Sample(webY: Int(web.minY.rounded()), webH: Int(web.height.rounded()),
                          layers: layers.sorted { $0.id < $1.id }, lozenges: Array(lozenges))
        if samples.last?.sample != next {
            samples.append((Int((CACurrentMediaTime() - startedAt) * 1000), next))
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        guard let bridge else { return }
        // A reversal on any visible layer: content drawn lower (shown offset
        // fell) and then higher again, or the web view itself moving.
        var worstDown = 0, worstUp = 0, worstId = "-"
        let ids = Set(samples.flatMap { $0.sample.layers.filter { $0.vis > 0 }.map(\.id) })
        for id in ids {
            let tops = samples.compactMap { s in s.sample.layers.first { $0.id == id && $0.vis > 0 }.map { s.sample.webY + $0.y - $0.shown } }
            guard let first = tops.first else { continue }
            var down = 0, up = 0, low = first
            for t in tops { down = max(down, t - first); low = max(low, t); up = max(up, low - t) }
            if min(down, up) > min(worstDown, worstUp) || (worstId == "-" && down + up > 0) { worstDown = down; worstUp = up; worstId = id }
        }
        bridge.handleConsoleLog("LOG: [ENTRYMOTION] \(label) frames=\(samples.count) worstVisibleLayer=\(worstId) down=\(worstDown)pt up=\(worstUp)pt")
        for chunk in stride(from: 0, to: samples.count, by: 8) {
            let lines = samples[chunk..<min(chunk + 8, samples.count)].map { s in
                let layers = s.sample.layers.map { "\($0.id):v\($0.vis) y\($0.y) h\($0.h) c\($0.content) o\($0.offset)/\($0.shown)" }.joined(separator: ",")
                return "+\(s.ms) web=\(s.sample.webY)/\(s.sample.webH) [\(layers)] lz=\(s.sample.lozenges)"
            }
            bridge.handleConsoleLog("LOG: [ENTRYMOTION] \(lines.joined(separator: " | "))")
        }
        samples = []
    }

    private final class Target: NSObject {
        weak var probe: ChatEntryMotionProbe?
        init(_ probe: ChatEntryMotionProbe) { self.probe = probe }
        @objc func frame(_ link: CADisplayLink) {
            MainActor.assumeIsolated { probe?.sample() }
        }
    }
}
#endif
