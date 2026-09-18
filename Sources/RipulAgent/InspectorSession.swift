#if os(iOS)
import SwiftUI
import UIKit
import WebKit

struct InspectorNativeSelection {
    let info: InspectedView
    let highlight: UIView
    let localPoint: CGPoint
}

/// One element gathered into the identity lozenge by a shift-click. Only the
/// identity is kept: the basket exists to be copied as a list of IDs, so a
/// rebuilt or removed view keeps its line.
struct InspectorCollectedElement: Identifiable, Equatable {
    let kind: String
    let identity: String
    var id: String { kind + "|" + identity }
}

struct InspectorWebElement: Decodable, Identifiable {
    struct Box: Decodable { let x, y, width, height: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    struct Viewport: Decodable { let width, height, offsetLeft, offsetTop: Double }
    struct BoxModel: Decodable {
        struct Sides: Decodable { let top, right, bottom, left: Double }
        struct Size: Decodable { let width, height: Double }
        let margin, border, padding: Sides
        let content: Size
    }
    struct Node: Decodable, Identifiable { let id, label: String }
    let id, label, tag, text, identifier, role, correlationId: String
    let rect: Box
    let viewport: Viewport
    let box: BoxModel
    let styles, attributes: [String: String]
    let ancestors, children: [Node]
    let `private`: Bool
    let privateRects: [Box]
    var reference: String {
        ["Web element: \(label)", "Tag: \(tag)", "Identifier: \(identifier)", "Role: \(role)",
         "Path: " + (ancestors.map(\.label) + [label]).joined(separator: " > "),
         "Text: \(text)", "Correlation: \(correlationId)",
         "Bounds (CSS pixels): \(rect.x), \(rect.y), \(rect.width) × \(rect.height)"].joined(separator: "\n")
    }
    var details: String {
        ["Tag: \(tag)", "Role: \(role)",
         "Path: " + (ancestors.map(\.label) + [label]).joined(separator: " > "),
         "Text: \(text)", "Correlation: \(correlationId)",
         "Bounds (CSS pixels): \(rect.x), \(rect.y), \(rect.width) × \(rect.height)"].joined(separator: "\n")
    }
}

/// One owner for native and DOM selection. A generation discards late WebKit
/// replies when the cursor has already crossed back into native content.
@MainActor
final class InspectorSession: ObservableObject {
    @Published private(set) var native: InspectedView?
    @Published private(set) var web: InspectorWebElement?
    @Published var pinned = false
    /// A hardware pointer (mouse / trackpad) is driving the explorer.
    ///
    /// Hover re-picks on EVERY cursor move, so with a mouse attached the
    /// highlight chases the pointer and an element can never be settled on —
    /// moving off it to reach the HUD replaces it first. Pointer mode therefore
    /// selects one shot: the click that picks also pins, and the reticle in the
    /// identity lozenge arms the next pick. Owned by `ViewInspectorController`,
    /// published here because the HUD renders from it.
    @Published var pointerActive = false
    @Published var interacting = false
    /// Elements gathered by shift-clicking with a pointer, in the order they
    /// were added. Listed under the identity lozenge and copied as one list.
    @Published private(set) var collected: [InspectorCollectedElement] = []
    /// Shift is held while a pointer drives the explorer. Hover keeps picking
    /// through the pin so the next shift-click can be aimed, and that click
    /// adds its element to `collected` instead of replacing the selection.
    /// Owned by `ViewInspectorController`, which reads the modifier off every
    /// hover and click.
    @Published private(set) var extending = false
    @Published var error: String?
    @Published private(set) var historyCount = 0
    weak var controller: ViewInspectorController?
    private(set) weak var webView: WKWebView?
    private var generation = 0
    private var picking = false
    /// One-shot pointer selection asked to pin, but a web pick was still in
    /// flight. See `lockWhenPickSettles()`.
    private var lockPending = false
    /// A shift-click asked to collect, but its web pick was still in flight.
    private var collectPending = false
    /// The pinned selection when a shift run began. It seeds the basket on the
    /// first shift-click (click A, shift-click B collects both, as in every
    /// desktop list), and it is restored when the run ends without a click,
    /// so holding shift and moving the mouse cannot lose a pinned element.
    private var extendingOrigin: (target: Target, element: InspectorCollectedElement)?
    private var pendingPick: (WKWebView, CGPoint, Int)?
    private struct Target {
        var native: InspectorNativeSelection?
        weak var webView: WKWebView?
        let webID: String?
    }
    private var history: [Target] = []
    private var target: Target?
    private static let source = (try? String(contentsOf: Bundle.module.url(forResource: "InspectorEngine", withExtension: "js")!)) ?? ""

    var hasSelection: Bool { native != nil || web != nil }
    var identity: String? {
        let candidates = web.map { [$0.identifier, $0.label, $0.tag] }
            ?? [native?.accessibilityId, native?.text, native?.className].compactMap { $0 }
        return candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var label: String { identity ?? "Inspector" }
    var kind: String { web == nil ? "Native" : "Web" }
    /// The current selection as a basket entry, when it has an identity.
    var current: InspectorCollectedElement? { identity.map { InspectorCollectedElement(kind: kind, identity: $0) } }
    /// One identity per line, in collection order: what Copy all puts on the clipboard.
    var collectedIdentities: String { collected.map(\.identity).joined(separator: "\n") }
    var canGoUp: Bool { web.map { !$0.ancestors.isEmpty || webView != nil } ?? (native?.view.superview != nil) }

    func waitForPick() async {
        let deadline = Date().addingTimeInterval(3)
        while picking && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        if picking { invalidate(); error = "The web view did not respond. Select the element again." }
    }

    func readWebSelection() async {
        guard let view = webView, let id = web?.id else { return }
        guard let window = view.window, RipulViewExplorer.canInspect(window) else { invalidate(); return }
        let ticket = generation
        do {
            let info = try Self.decode(try await Self.call(view, "read", [id]))
            if ticket == generation { web = info }
        } catch { if ticket == generation { invalidate(); self.error = error.localizedDescription } }
    }

    func activateWeb() async -> [String: Any] {
        guard let view = webView, let id = web?.id else { return ["success": false, "error": "No web element selected"] }
        guard let window = view.window, RipulViewExplorer.canInspect(window) else {
            invalidate()
            return ["success": false, "error": "The selected window is no longer available for inspection"]
        }
        do {
            _ = try await Self.call(view, "activate", [id])
            return ["success": true, "via": "DOM", "activatedId": web?.identifier ?? id]
        } catch { return ["success": false, "error": error.localizedDescription] }
    }

    static func call(_ view: WKWebView, _ operation: String, _ parameters: [Any] = []) async throws -> Any? {
        let value = try await view.callAsyncJavaScript(
            Self.source + "\ntry { return { value: await window.__ripulInspector[operation](...parameters) }; } catch(e) { return { error: String(e.message || e) }; }",
            arguments: ["operation": operation, "parameters": parameters], in: nil, contentWorld: .page)
        let reply = value as? [String: Any]
        if let error = reply?["error"] as? String { throw ComposerScreenContext.ElementUnavailable(message: error) }
        return reply?["value"]
    }

    private static func decode(_ value: Any?) throws -> InspectorWebElement? {
        guard let value, !(value is NSNull) else { return nil }
        return try JSONDecoder().decode(InspectorWebElement.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func remember(_ next: Target, remembering: Bool) {
        let same = target?.native?.info.view === next.native?.info.view
            && target?.native?.info.accessibilityId == next.native?.info.accessibilityId
            && target?.native?.highlight === next.native?.highlight
            && target?.webView === next.webView && target?.webID == next.webID
        if !same, remembering, let target {
            history.append(target)
            if history.count > 50 { history.removeFirst() }
        }
        target = next
        historyCount = history.count
    }

    func selectNative(_ info: InspectedView, remembering: Bool = true) {
        generation += 1; pendingPick = nil
        clearWebHighlight()
        let selection = controller?.nativeSelection ?? InspectorNativeSelection(info: info, highlight: info.view,
            localPoint: CGPoint(x: info.view.bounds.midX, y: info.view.bounds.midY))
        remember(Target(native: selection, webID: nil), remembering: remembering)
        web = nil; webView = nil; native = info; error = nil
    }

    func pickWeb(_ view: WKWebView, at point: CGPoint) {
        guard !pinned || extending, !interacting else { return }
        generation += 1
        pendingPick = (view, point, generation)
        guard !picking else { return }
        picking = true
        Task {
            while let (view, point, ticket) = pendingPick {
                pendingPick = nil
                do {
                    // UIKit points and CSS pixels differ under page zoom. Convert
                    // using the current layout viewport in the same JS operation.
                    let value = try await Self.call(view, "pickInView", [point.x, point.y, view.bounds.width, view.bounds.height])
                    guard ticket == generation, !pinned || extending, !interacting else {
                        if webView !== view { _ = try? await Self.call(view, "clear") }
                        continue
                    }
                    guard let info = try Self.decode(value) else { invalidate(); continue }
                    adoptWeb(info, view: view)
                } catch {
                    if ticket == generation { invalidate(); self.error = error.localizedDescription }
                }
            }
            picking = false
            applyPendingLock()
        }
    }

    /// Pin the selection as soon as the in-flight pick has settled.
    ///
    /// One-shot pointer selection cannot simply set `pinned` on the click: a web
    /// pick is asynchronous, and `pickWeb`'s continuation DISCARDS its reply when
    /// `pinned` has turned true in the meantime — so the click would lock an
    /// empty selection and throw away the very element it was aimed at. A native
    /// pick has already completed by the time this is called, so it pins now.
    ///
    /// `collecting` is the shift-click: once settled, the element is toggled in
    /// the basket as well as locked.
    func lockWhenPickSettles(collecting: Bool = false) {
        if picking {
            lockPending = true
            collectPending = collectPending || collecting
        } else {
            pinned = true
            if collecting { collectCurrent() }
        }
    }

    /// Arm the next one-shot pick: hover picks again until the next click.
    func armPointerSelection() {
        lockPending = false
        collectPending = false
        extendingOrigin = nil
        pinned = false
        controller?.repickAtCursor()
    }

    private func applyPendingLock() {
        guard lockPending else { return }
        lockPending = false
        pinned = true
        if collectPending {
            collectPending = false
            collectCurrent()
        }
    }

    // MARK: Shift-click collection

    /// Shift went down or up with a pointer attached. Entering a run while
    /// pinned remembers that selection as the origin; leaving a run that never
    /// clicked puts it back.
    func setExtending(_ on: Bool) {
        guard on != extending else { return }
        extending = on
        if on {
            if pinned, let target, let current { extendingOrigin = (target, current) }
        } else if let origin = extendingOrigin {
            extendingOrigin = nil
            if !isCurrent(origin.target) { restore(origin.target) }
        }
    }

    /// Toggle the current selection in the basket. The first collection of a
    /// run also seeds the pinned origin, so the pair reads as both elements.
    func collectCurrent() {
        guard let current else { return }
        if let origin = extendingOrigin {
            extendingOrigin = nil
            if collected.isEmpty, origin.element != current { collected.append(origin.element) }
        }
        if let index = collected.firstIndex(of: current) { collected.remove(at: index) }
        else { collected.append(current) }
    }

    func removeCollected(_ element: InspectorCollectedElement) {
        collected.removeAll { $0 == element }
    }

    func clearCollected() {
        collected = []
        extendingOrigin = nil
    }

    func copyCollected() {
        guard !collected.isEmpty else { return }
        UIPasteboard.general.string = collectedIdentities
    }

    private func isCurrent(_ candidate: Target) -> Bool {
        candidate.native?.info.view === target?.native?.info.view
            && candidate.webView === target?.webView && candidate.webID == target?.webID
    }

    /// Re-select a remembered target if it is still on screen.
    @discardableResult
    private func restore(_ candidate: Target) -> Bool {
        if let selection = candidate.native, selection.info.view.window != nil {
            controller?.restoreNativeSelection(selection, remembering: false); return true
        }
        if let view = candidate.webView, view.window != nil, let id = candidate.webID {
            selectWeb(id: id, remembering: false, in: view); return true
        }
        return false
    }

    private func adoptWeb(_ info: InspectorWebElement, view: WKWebView, remembering: Bool = true) {
        guard let window = view.window, RipulViewExplorer.canInspect(window) else { invalidate(); return }
        if webView !== view { clearWebHighlight() }
        remember(Target(webView: view, webID: info.id), remembering: remembering)
        native = nil; webView = view; web = info; error = nil
    }

    func invalidate() {
        generation += 1; pendingPick = nil; lockPending = false; collectPending = false
        clearWebHighlight(); web = nil; native = nil; target = nil; webView = nil
    }

    func clearWebHighlight() {
        if let view = webView { Task { _ = try? await Self.call(view, "clear") } }
    }

    func close() {
        invalidate(); clearCollected(); extending = false; controller = nil
    }

    func selectWeb(id: String, remembering: Bool = true, in view: WKWebView? = nil) {
        guard let view = view ?? webView else { return }
        guard let window = view.window, RipulViewExplorer.canInspect(window) else { invalidate(); return }
        generation += 1; let ticket = generation
        Task {
            do {
                guard let info = try Self.decode(try await Self.call(view, "select", [id])), ticket == generation else { return }
                adoptWeb(info, view: view, remembering: remembering)
            } catch { if ticket == generation { invalidate(); self.error = error.localizedDescription } }
        }
    }

    func selectView(_ view: UIView, remembering: Bool = true) {
        controller?.selectNativeView(view, remembering: remembering)
    }

    func up() {
        if let parent = web?.ancestors.last { selectWeb(id: parent.id) }
        else if let view = webView { selectView(view) }
        else if let parent = native?.view.superview { selectView(parent) }
    }

    func back() {
        while let previous = history.popLast() {
            historyCount = history.count
            if restore(previous) { return }
        }
    }

    func refresh() {
        if let id = web?.id { selectWeb(id: id, remembering: false) }
        else if let selection = controller?.nativeSelection { controller?.restoreNativeSelection(selection, remembering: false) }
    }

    func editStyle(_ property: String, value: String) async {
        guard let view = webView, let id = web?.id else { return }
        let ticket = generation
        do {
            let info = try Self.decode(try await Self.call(view, "style", [id, property, value]))
            if ticket == generation { web = info; error = nil }
        } catch { if ticket == generation { self.error = error.localizedDescription } }
    }

    func evaluate(_ expression: String) async -> String {
        guard let view = webView, let id = web?.id else { return "Select a web element first." }
        do { return (try await Self.call(view, "evaluate", [id, expression])) as? String ?? "undefined" }
        catch { return error.localizedDescription }
    }

    func activate() {
        if let view = webView, let id = web?.id {
            guard let window = view.window, RipulViewExplorer.canInspect(window) else { invalidate(); return }
            Task {
                do { _ = try await Self.call(view, "activate", [id]); refresh() }
                catch { self.error = error.localizedDescription }
            }
        } else { controller?.activateSelection() }
    }

    func copy() {
        UIPasteboard.general.string = web?.reference ?? native?.sourceReference()
    }

    func copyIdentity() {
        guard let identity else { return }
        UIPasteboard.general.string = identity
    }

    func captureWeb(configuration: RipulScreenContextConfiguration) async throws -> RipulScreenContextSnapshot {
        guard let view = webView, let id = web?.id, view.window != nil,
              let info = try Self.decode(try await Self.call(view, "read", [id])) else {
            throw ComposerScreenContext.ElementUnavailable(message: "Select a visible element first.")
        }
        guard !info.private else { throw ComposerScreenContext.ElementUnavailable(message: "This element is excluded from context capture.") }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard current.ripulAIContext?.isExcluded != true, !current.isHidden, current.alpha > 0.01 else {
                throw ComposerScreenContext.ElementUnavailable(message: "This element is excluded from context capture.")
            }
            ancestor = current.superview
        }
        var jpeg: Data?
        if configuration.available.contains(.screenshot) {
            let sx = view.bounds.width / info.viewport.width, sy = sx
            let frame = CGRect(x: (info.rect.x - info.viewport.offsetLeft) * sx,
                y: (info.rect.y - info.viewport.offsetTop) * sy, width: info.rect.width * sx, height: info.rect.height * sy).intersection(view.bounds)
            guard !frame.isEmpty, !frame.isNull else { throw ComposerScreenContext.ElementUnavailable(message: "This element is offscreen.") }
            _ = try await Self.call(view, "clear")
            let config = WKSnapshotConfiguration(); config.rect = frame
            do {
                let image = try await view.takeSnapshot(configuration: config)
                guard let after = try Self.decode(try await Self.call(view, "read", [id])), !after.private,
                      after.rect.cgRect == info.rect.cgRect else {
                    throw ComposerScreenContext.ElementUnavailable(message: "The screen changed during capture. Select the element again.")
                }
                let masked = UIGraphicsImageRenderer(size: image.size).image { context in
                    image.draw(at: .zero)
                    UIColor.black.setFill()
                    for r in info.privateRects + after.privateRects {
                        let rect = CGRect(x: ((r.x - info.viewport.offsetLeft) * sx - frame.minX) * image.size.width / frame.width,
                            y: ((r.y - info.viewport.offsetTop) * sy - frame.minY) * image.size.height / frame.height,
                            width: r.width * sx * image.size.width / frame.width, height: r.height * sy * image.size.height / frame.height)
                        context.fill(rect)
                    }
                }
                jpeg = masked.jpegData(compressionQuality: 0.8)
            } catch {
                _ = try? await Self.call(view, "select", [id]); throw error
            }
            _ = try? await Self.call(view, "select", [id])
        }
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
        var result = RipulScreenContextSnapshot(appDescription: "Host app: \(app)\nSelected Inspector web element",
            instrumentedText: info.reference, screenshotJPEG: jpeg, accessibleFallback: info.text, configuration: configuration)
        result.attachmentTitle = "Element — " + String(info.label.prefix(80))
        return result
    }
}
#endif
