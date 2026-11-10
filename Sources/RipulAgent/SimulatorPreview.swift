import Foundation

struct SimulatorTarget: Decodable, Equatable, Hashable {
    let udid: String
    var developerDir: String? = nil
    var deviceSet: String? = nil

    var arguments: [String: Any] {
        var result: [String: Any] = ["udid": udid]
        if let developerDir { result["developerDir"] = developerDir }
        if let deviceSet { result["deviceSet"] = deviceSet }
        return result
    }
}

#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// What the chat on screen has of its simulator picture-in-picture, for a host
/// that keeps the minimised panel's button in its own chrome
/// (`AgentBridge.simulatorPreviewPresence`).
public enum SimulatorPreviewPresence: Equatable, Sendable {
    /// No simulator, or the window's dock is showing it.
    case none
    /// The panel shows the simulator.
    case open
    /// The panel is minimised to its button.
    case minimised
}

/// The PiP owns simulator selection and hardware actions; a host app can place
/// these controls beside its live viewer, including in unused letterboxes.
public struct SimulatorFullScreenControls {
    public struct Action {
        public let id: String
        public let title: String
        public let symbol: String
        public let perform: () -> Void
    }
    public let screenSize: CGSize
    public let actions: [Action]
    public let simulatorMenu: UIMenu?
    /// Back to the picture-in-picture panel: from full screen, or out of the dock.
    public let restore: () -> Void
    /// Shown in the window's dock beside the app (`PreviewDockState`), not over it:
    /// restore undocks, and `close` closes it there.
    public var docked = false
    public var close: (() -> Void)? = nil
    /// The toolbar stands down where the screen leaves it no margin (a dock
    /// fitted to the simulator): the dock's divider offers the same controls.
    public var hidesToolbarWithoutRoom = false
    /// The live picture measured the simulator's screen, in points.
    public var onScreenSize: ((CGSize) -> Void)? = nil
}

/// Frames and capture lifecycle belong to this leaf, never AgentBridge's published state.
///
/// The picture is read from the simulator itself on its Mac (`simulatorSnapshot`,
/// SimulatorScreens.swift there), not from a window: Xcode 27 shows simulators
/// in Device Hub, one device per window, and a simulator an agent booted has no
/// window at all. Control swaps the still for live video that takes the
/// person's fingers, made by the host app (`AgentBridge.simulatorLiveContent`).
///
/// Each chat keeps its own panel: leaving a chat puts it away as it was, and
/// coming back brings it back, closed included.
@MainActor
final class SimulatorPreviewState: ObservableObject {
    struct Selection: Equatable {
        let target: SimulatorTarget
        let machineId: String
        let chatId: String
    }
    /// A chat's panel while another chat is showing.
    private struct Kept {
        var selection: Selection
        var targets: [SimulatorTarget]
        var collapsed: Bool
    }
    typealias Invoke = (String, String, [Any], String) async -> [String: Any]
    /// Live video of a simulator that takes fingers: (UDID, Mac) to a view, from the host app.
    typealias LiveContent = (String, String) -> AnyView
    typealias FullScreenPresentation = (String, String, SimulatorFullScreenControls) -> AnyView
    /// Floats the simulator into a dedicated window on Mac Catalyst: (UDID, Mac, Name, Foldable).
    typealias FloatWindow = (String, String, String, Bool) -> Void
    @Published private(set) var selection: Selection?
    /// The chat's simulators, oldest first; more than one offers a switch between them.
    @Published private(set) var targets: [SimulatorTarget] = []
    /// Simulators' names by UDID, as their Mac said them.
    @Published private(set) var names: [String: String] = [:]
    let frame = HostScreenPreviewFrame()
    var image: UIImage? { frame.image }
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var logicalScreenSize: CGSize = .zero
    private var lastJPEG: String?
    @Published private(set) var appearance: WindowPreviewAppearance?
    @Published private(set) var chrome: SimulatorDisplayChrome?
    @Published private(set) var error: String?
    /// The simulator's name, once its Mac has said it.
    @Published private(set) var title = "Simulator"
    /// The simulator has two screens of its own and can be opened and closed (the iPhone Duo).
    @Published private(set) var foldable = false
    /// What a control just said, shown for a few seconds.
    @Published private(set) var notice: String?
    /// Asks the Mac, for the controls; set by the panel's controller.
    var invoke: Invoke?
    private var noticeGeneration = UUID()
    /// What a panel floated from the Simulators screen keeps its simulators
    /// under: it belongs to no chat (`AgentBridge.floatSimulator`).
    static let floatedChatId = "ripul.floated"
    /// The panel's Close takes the simulator away rather than minimising it:
    /// a floated panel has no chat for it to wait in.
    var closeDismisses = false
    @Published var collapsed = false
    /// The host app keeps the minimised panel's button in its own chrome (the
    /// iPhone Duo's side strip, `AgentBridge.simulatorPreviewButtonHosted`):
    /// minimised, the panel then floats no round button of its own.
    @Published var buttonHosted = false
    /// The person is driving the simulator: live video that takes their fingers.
    @Published var live = false
    /// The simulator is maximized to fill the whole screen, as in the Simulators pane.
    @Published var maximized = false
    /// One of the panel's own gestures (a move, a resize, a pinch) has it, or
    /// let go of it a moment ago: its buttons don't press, since a finger that
    /// began on one lifts as a press of it.
    var gestureHoldsButtons = false
    @Published private(set) var fullScreenGeneration = UUID()
    @Published var allowed = true
    var liveContent: LiveContent?
    var fullScreenContent: LiveContent?
    var fullScreenPresentation: FullScreenPresentation?
    var floatWindow: FloatWindow?

    var canMaximize: Bool { fullScreenPresentation != nil || fullScreenContent != nil || liveContent != nil }
    /// The window's dock (`PreviewDockState`), where a wide window can hold a simulator beside the app.
    weak var dock: PreviewDockState? { didSet { watchDock() } }
    /// The simulator the window's dock is showing. Its panel leaves it to the dock.
    @Published private(set) var dockedUdid: String?
    private var dockWatch: AnyCancellable?
    /// The simulator this app runs in, when it does.
    var ownSimulatorUdid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
    private var kept: [String: Kept] = [:]
    /// Targets opened automatically (`automatic: true`) per chat, so a deleted
    /// simulator that the agent opened can be evicted without leaving an error box.
    private var automaticTargets: [String: Set<SimulatorTarget>] = [:]
    /// Called when a snapshot reveals that a simulator no longer exists on the Mac.
    var onSimulatorGone: ((String, String) -> Void)?
    private(set) var visibleChatId: String?
    private var generation = UUID()
    private var inFlight = false
    /// After a failure the panel asks again every few seconds, as the browser
    /// panel keeps asking: a Mac restarting, or a simulator booting, heals by
    /// itself. Retry asks at once.
    private var failedAt: Date?
    private var namesAsked: Set<String> = []
    static let askAgainAfterFailure: TimeInterval = 5
    /// The picture's width in pixels: the panel's, set as it is drawn. A fixed
    /// 320 was blurry on a 2x or 3x screen beside the live video.
    var pictureWidth = 640
    static func pictureWidth(points: CGFloat, scale: CGFloat) -> Int {
        min(900, max(320, Int((points * max(scale, 1)).rounded())))
    }
    /// How long a fold takes to settle before Control comes back on the new screen.
    var foldSettles: Duration = .milliseconds(700)
    var clock: () -> Date = Date.init

    var aspectRatio: CGFloat { imageSize.height > 0 ? imageSize.width / imageSize.height : 0.47 }

    var effectiveChrome: SimulatorDisplayChrome {
        if let chrome { return chrome }
        if imageSize.width > imageSize.height { return .defaultLandscapePhone }
        return .defaultPhone
    }

    var effectiveScreenSize: CGSize {
        if logicalScreenSize.width > 0, logicalScreenSize.height > 0 {
            return logicalScreenSize
        }
        if imageSize.width > 0, imageSize.height > 0 {
            let shortSide = min(imageSize.width, imageSize.height)
            let scale = 393.0 / max(shortSide, 1)
            return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }
        return CGSize(width: 393, height: 852)
    }

    var chassisAspectRatio: CGFloat {
        let screen = effectiveScreenSize
        let outsets = SimulatorChromePath.totalOutsets(for: effectiveChrome, includesButtonPadding: true)
        let totalW = screen.width + outsets.left + outsets.right
        let totalH = screen.height + outsets.top + outsets.bottom
        return totalH > 0 ? totalW / totalH : aspectRatio
    }

    /// The share of the chassis's height that is the empty band above the
    /// simulator's frame: the room the buttons cut into its top border had.
    /// The panel tucks it under its toolbar.
    var chassisTopBand: CGFloat {
        let chrome = effectiveChrome
        let outsets = SimulatorChromePath.totalOutsets(for: chrome, includesButtonPadding: true)
        let totalH = effectiveScreenSize.height + outsets.top + outsets.bottom
        guard totalH > 0 else { return 0 }
        return min(max((outsets.top - CGFloat(chrome.bezelTop)) / totalH, 0), 0.5)
    }

    /// `automatic` is the agent reaching for the simulator (a borrowed one, a
    /// tool call that names it), not the person asking. As with the browser
    /// preview, a later automatic open in the same chat keeps the person's
    /// minimise, and one for the simulator already showing changes nothing. A
    /// simulator being driven is never taken away: a new one waits in the switch.
    func open(_ target: SimulatorTarget, machineId: String, chatId: String, automatic: Bool = false) {
        // An agent driving this very app in a simulator, as agents testing
        // Ripul do: its picture here would be this screen inside itself.
        if let own = ownSimulatorUdid, own.caseInsensitiveCompare(target.udid) == .orderedSame { return }
        if visibleChatId == nil { visibleChatId = chatId }
        guard chatId == visibleChatId else {
            // A chat out of sight: its panel opens there for when it is shown.
            var away = kept[chatId] ?? Kept(selection: Selection(target: target, machineId: machineId, chatId: chatId),
                                            targets: [], collapsed: false)
            let isNew = !away.targets.contains(target)
            if isNew {
                away.targets.append(target)
                if automatic { automaticTargets[chatId, default: []].insert(target) }
            }
            if !automatic {
                automaticTargets[chatId]?.remove(target)
                away.selection = Selection(target: target, machineId: machineId, chatId: chatId)
                away.collapsed = false
            } else if isNew {
                away.selection = Selection(target: target, machineId: machineId, chatId: chatId)
            }
            kept[chatId] = away
            return
        }
        let next = Selection(target: target, machineId: machineId, chatId: chatId)
        let hadPanel = selection != nil
        if !targets.contains(target) {
            targets.append(target)
            if automatic { automaticTargets[chatId, default: []].insert(target) }
        }
        if !automatic {
            automaticTargets[chatId]?.remove(target)
        }
        if selection != next {
            if automatic, (live || maximized), selection != nil { return }
            select(next)
        } else if !automatic, error != nil {
            retry()
        }
        if !automatic || !hadPanel { collapsed = false }
    }

    /// Drops a simulator that was deleted on the Mac (`simctl delete` or no longer in Xcode).
    func forget(udid: String, chatId: String) {
        let matches: (SimulatorTarget) -> Bool = { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
        if let existing = automaticTargets[chatId] {
            automaticTargets[chatId] = Set(existing.filter { !matches($0) })
        }
        guard chatId == visibleChatId else {
            guard var away = kept[chatId] else { return }
            away.targets.removeAll(where: matches)
            if matches(away.selection.target) {
                if let fallback = away.targets.last {
                    away.selection = Selection(target: fallback, machineId: away.selection.machineId, chatId: chatId)
                    kept[chatId] = away
                } else {
                    kept[chatId] = nil
                }
            } else {
                kept[chatId] = away
            }
            return
        }
        targets.removeAll(where: matches)
        guard let current = selection, matches(current.target) else { return }
        if let fallback = targets.last {
            select(Selection(target: fallback, machineId: current.machineId, chatId: current.chatId))
        } else {
            close()
        }
    }

    /// Shows another of the chat's simulators.
    func switchTo(_ target: SimulatorTarget) {
        guard let selection, targets.contains(target), selection.target != target else { return }
        select(Selection(target: target, machineId: selection.machineId, chatId: selection.chatId))
        collapsed = false
    }

    func close() {
        if let chat = visibleChatId {
            kept[chat] = nil
            automaticTargets[chat] = nil
        }
        generation = UUID()
        selection = nil; targets = []; live = false; maximized = false
        resetFrame(); error = nil; appearance = nil; title = "Simulator"; foldable = false
    }

    func maximize() {
        guard selection != nil, canMaximize else { return }
        collapsed = false
        fullScreenGeneration = UUID()
        maximized = true
    }

    func restoreFromMaximize() {
        guard maximized else { return }
        maximized = false
        if !live { retry() }
    }

    func floatOut() {
        guard let selection, let floatWindow else { return }
        let udid = selection.target.udid
        let resolvedName = names[udid] ?? (title == "Simulator" ? "Simulator \(udid.prefix(8))" : title)
        floatWindow(udid, selection.machineId, resolvedName, foldable)
        live = false
        maximized = false
        collapsed = true
    }

    // MARK: The window's dock

    /// The panel's simulator is the one in the dock.
    var isDocked: Bool { Self.isDocked(selection, dockedUdid: dockedUdid) }

    /// What the visible chat's panel shows: nothing (no simulator, or the
    /// dock has it), the picture, or the minimised button.
    static func presence(_ selection: Selection?, collapsed: Bool, dockedUdid: String?) -> SimulatorPreviewPresence {
        guard selection != nil, !isDocked(selection, dockedUdid: dockedUdid) else { return .none }
        return collapsed ? .minimised : .open
    }

    /// The host's own button for the panel: opens it, or minimises it.
    func toggleFromHostButton() {
        guard selection != nil, !isDocked else { return }
        if collapsed {
            collapsed = false
        } else {
            live = false
            collapsed = true
        }
    }

    static func isDocked(_ selection: Selection?, dockedUdid: String?) -> Bool {
        guard let selection, let dockedUdid else { return false }
        return selection.target.udid.caseInsensitiveCompare(dockedUdid) == .orderedSame
    }

    /// Let go in the window's right edge: the dock takes the simulator, live.
    func dockIntoWindow() {
        guard let selection, let dock else { return }
        let docked = PreviewDockState.Simulator(
            target: selection.target, machineId: selection.machineId, chatId: selection.chatId,
            name: names[selection.target.udid] ?? title, foldable: foldable, screenSize: effectiveScreenSize)
        // The dock has its own live picture; out of it, the panel comes back open.
        live = false
        maximized = false
        collapsed = false
        dock.dock(.simulator(docked))
    }

    /// Out of the dock: the simulator's panel again, in its own chat, open or minimised.
    func returnFromDock(_ docked: PreviewDockState.Simulator, open reopened: Bool) {
        if let own = ownSimulatorUdid, own.caseInsensitiveCompare(docked.udid) == .orderedSame { return }
        let next = Selection(target: docked.target, machineId: docked.machineId, chatId: docked.chatId)
        if visibleChatId == nil || visibleChatId == docked.chatId {
            visibleChatId = docked.chatId
            if !targets.contains(docked.target) { targets.append(docked.target) }
            if selection != next { select(next) } else { retry() }
            collapsed = !reopened
        } else {
            // Another chat is showing: the panel waits in the simulator's own chat.
            var away = kept[docked.chatId] ?? Kept(selection: next, targets: [], collapsed: !reopened)
            if !away.targets.contains(docked.target) { away.targets.append(docked.target) }
            away.selection = next
            away.collapsed = !reopened
            kept[docked.chatId] = away
        }
    }

    private func watchDock() {
        dockWatch = dock?.$shown.sink { [weak self] shown in
            guard let self else { return }
            let udid: String? = if case .simulator(let simulator) = shown { simulator.udid } else { nil }
            if self.dockedUdid != udid { self.dockedUdid = udid }
        }
    }

    /// Restores or ensures the collapsed simulator FAB button for `chatId`
    /// without auto-expanding the preview panel (for example after a popped-out
    /// simulator window is closed).
    func ensureCollapsedFAB(_ target: SimulatorTarget, machineId: String, chatId: String) {
        if let own = ownSimulatorUdid, own.caseInsensitiveCompare(target.udid) == .orderedSame { return }
        if visibleChatId == nil { visibleChatId = chatId }
        guard chatId == visibleChatId else {
            var away = kept[chatId] ?? Kept(
                selection: Selection(target: target, machineId: machineId, chatId: chatId),
                targets: [],
                collapsed: true
            )
            if !away.targets.contains(target) { away.targets.append(target) }
            kept[chatId] = away
            return
        }
        if !targets.contains(target) { targets.append(target) }
        if selection == nil {
            select(Selection(target: target, machineId: machineId, chatId: chatId))
            collapsed = true
        }
    }

    func retry() {
        generation = UUID()
        resetFrame(); error = nil
    }

    #if DEBUG
    /// The fixture's panel stays on screen whatever chat is.
    private var fixtureHeld = false

    /// `-ripul.fixture.simulatorPanel`: a simulator's panel from launch, with
    /// no chat or Mac to hand, to see it beside the Duo's strip on a
    /// simulator. Its Mac does not exist, so the panel says it cannot reach it.
    func openFixture() {
        fixtureHeld = true
        visibleChatId = "fixture"
        open(SimulatorTarget(udid: "00000000-0000-4000-8000-000000000002"), machineId: "fixture", chatId: "fixture")
    }
    #endif

    /// The chat on screen changed: put this chat's panel away and bring back that one's.
    func show(chatId: String?) {
        #if DEBUG
        if fixtureHeld { return }
        #endif
        guard chatId != visibleChatId else { return }
        if let leaving = visibleChatId, let selection {
            kept[leaving] = Kept(selection: selection, targets: targets, collapsed: collapsed)
        }
        visibleChatId = chatId
        generation = UUID()
        resetFrame(); error = nil; appearance = nil; live = false; maximized = false; foldable = false
        if let chatId, let back = kept.removeValue(forKey: chatId) {
            selection = back.selection; targets = back.targets; collapsed = back.collapsed
            title = names[back.selection.target.udid] ?? "Simulator"
        } else {
            selection = nil; targets = []; collapsed = false; title = "Simulator"
        }
    }

    /// The simulator's hardware controls, as on its Mac (`screenWindows.simulatorControl`):
    /// `home`, `appSwitcher`, `rotateLeft`, `rotateRight`, and for a foldable
    /// `open`, `halfOpen` and `close`.
    struct Control: Identifiable {
        let action: String, title: String, symbol: String
        var id: String { action }
    }
    static let controls = [
        Control(action: "home", title: "Home", symbol: "house"),
        Control(action: "appSwitcher", title: "App Switcher", symbol: "square.stack"),
        Control(action: "rotateLeft", title: "Rotate Left", symbol: "rotate.left"),
        Control(action: "rotateRight", title: "Rotate Right", symbol: "rotate.right"),
    ]
    /// An Android emulator's (AndroidEmulatorUDID): its navigation bar's three and the turns.
    static let androidControls = [
        Control(action: "back", title: "Back", symbol: "chevron.backward"),
        Control(action: "home", title: "Home", symbol: "circle"),
        Control(action: "appSwitcher", title: "Recents", symbol: "square"),
        Control(action: "rotateLeft", title: "Rotate Left", symbol: "rotate.left"),
        Control(action: "rotateRight", title: "Rotate Right", symbol: "rotate.right"),
    ]
    /// The buttons for the simulator showing: an Android emulator has its own.
    var hardwareControls: [Control] {
        guard let udid = selection?.target.udid, AndroidEmulatorUDID.isAndroid(udid) else { return Self.controls }
        return Self.androidControls
    }
    static let foldControls = [
        Control(action: "open", title: "Open", symbol: "book"),
        Control(action: "halfOpen", title: "Half Open", symbol: "book.closed"),
        Control(action: "close", title: "Close", symbol: "rectangle.portrait"),
    ]

    func control(_ action: String) async {
        guard let selection, let invoke else { return }
        let response = await invoke(selection.machineId, "simulatorControl", [selection.target.arguments, ["action": action]], selection.chatId)
        guard response["success"] as? Bool == true else {
            let said = response["error"] as? String
            show(notice: said.map { $0.contains("Unknown method") || $0.contains("NOT_ALLOWED") || $0.contains("not available through Direct")
                ? "Update Ripul on the Mac to use simulator controls." : $0 } ?? "The Mac didn't answer.")
            return
        }
        // Control stays on. A fold moves the picture to the other screen, so the
        // live video starts again on it once the fold has settled; a turn
        // changes nothing the video holds. The pictures take a fresh one.
        let isFold = Self.foldControls.contains(where: { $0.action == action })
        guard action.hasPrefix("rotate") || isFold else { return }
        if maximized, isFold {
            let folded = generation
            try? await Task.sleep(for: foldSettles)
            guard generation == folded, self.selection == selection, allowed else { return }
            fullScreenGeneration = UUID()
            return
        }
        guard live, isFold else {
            if !live && !maximized { retry() }
            return
        }
        live = false
        retry()
        let folded = generation
        try? await Task.sleep(for: foldSettles)
        // Not if the person moved on meanwhile: another simulator, another chat, or closed.
        guard generation == folded, self.selection == selection, allowed else { return }
        live = true
    }

    func setLive(_ enabled: Bool) {
        guard live != enabled else { return }
        live = enabled
        if enabled {
            show(notice: "Control mode — touch to interact, drag the toolbar to move")
        } else {
            show(notice: "View mode — preview only")
        }
    }

    private func show(notice text: String) {
        let generation = UUID()
        noticeGeneration = generation
        notice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if noticeGeneration == generation { notice = nil }
        }
    }

    private func select(_ next: Selection) {
        generation = UUID()
        selection = next
        live = false
        fullScreenGeneration = UUID()
        resetFrame(); error = nil; appearance = nil; foldable = false
        title = names[next.target.udid] ?? "Simulator"
    }

    func refresh(invoke: Invoke) async {
        guard let selection, allowed, !collapsed, !live, !maximized, !isDocked, !inFlight else { return }
        if error != nil, let failedAt, clock().timeIntervalSince(failedAt) < Self.askAgainAfterFailure { return }
        inFlight = true
        let version = generation
        func current() -> Bool { version == generation && allowed && !collapsed && !live && !maximized && !isDocked && !Task.isCancelled }
        do {
            // Small, view-only pictures over the Dock's authenticated remoting path.
            // One request at a time; the UI's timer waits a second AFTER it finishes.
            let response = await invoke(selection.machineId, "simulatorSnapshot", [selection.target.arguments, pictureWidth, 0.6], selection.chatId)
            guard current() else { inFlight = false; return }
            guard response["success"] as? Bool == true, let frame = response["result"] as? [String: Any] else {
                let rawError = response["error"] as? String
                if Self.isGone(rawError), evictGoneSelection(selection) {
                    inFlight = false
                    if self.selection != nil {
                        await refresh(invoke: invoke)
                    }
                    return
                }
                throw PreviewError.message(Self.explain(rawError))
            }
            if error != nil { error = nil }
            let canFold = frame["foldable"] as? Bool ?? false
            if foldable != canFold { foldable = canFold }
            if let name = frame["name"] as? String, !name.isEmpty {
                if names[selection.target.udid] != name { names[selection.target.udid] = name }
                if title != name { title = name }
            }
            let nextAppearance = WindowPreviewAppearance(frame["appearance"])
            if appearance != nextAppearance { appearance = nextAppearance }
            let nextChrome = (frame["chrome"] as? [String: Any]).flatMap(SimulatorDisplayChrome.init(json:))
            if chrome != nextChrome { chrome = nextChrome }
            if let w = (frame["width"] as? NSNumber)?.doubleValue,
               let h = (frame["height"] as? NSNumber)?.doubleValue,
               w > 0, h > 0 {
                let nextLogical = CGSize(width: w, height: h)
                if logicalScreenSize != nextLogical { logicalScreenSize = nextLogical }
            }
            guard let base64 = frame["jpegB64"] as? String else {
                throw PreviewError.message("The Mac returned an unreadable preview. Retry to reconnect.")
            }
            if base64 != lastJPEG {
                guard let data = Data(base64Encoded: base64), let next = UIImage(data: data) else {
                    throw PreviewError.message("The Mac returned an unreadable preview. Retry to reconnect.")
                }
                lastJPEG = base64
                if imageSize != next.size { imageSize = next.size }
                self.frame.image = next
            }
            await nameAnotherSimulator(showing: selection, invoke: invoke, current: current)
            inFlight = false
        } catch {
            inFlight = false
            guard current() else { return }
            failedAt = clock()
            if self.error != error.localizedDescription { self.error = error.localizedDescription }
        }
    }

    private static func isGone(_ error: String?) -> Bool {
        error?.contains("no longer available") == true
    }

    /// Evicts an automatically-opened simulator that no longer exists in Xcode,
    /// switching to another simulator in the chat or closing the automatic panel.
    private func evictGoneSelection(_ current: Selection) -> Bool {
        onSimulatorGone?(current.chatId, current.target.udid)
        guard automaticTargets[current.chatId]?.contains(current.target) == true else { return false }
        targets.removeAll { $0 == current.target }
        automaticTargets[current.chatId]?.remove(current.target)
        if let fallback = targets.last {
            select(Selection(target: fallback, machineId: current.machineId, chatId: current.chatId))
        } else {
            close()
        }
        return true
    }

    /// The switch lists the chat's simulators by name, and one never shown has
    /// none until its Mac says it: each refresh asks for one of them, a
    /// thumbnail for its name, until every one has been asked once.
    private func nameAnotherSimulator(showing: Selection, invoke: Invoke, current: () -> Bool) async {
        guard let unnamed = targets.first(where: { $0 != showing.target && names[$0.udid] == nil && !namesAsked.contains($0.udid) })
        else { return }
        namesAsked.insert(unnamed.udid)
        let response = await invoke(showing.machineId, "simulatorSnapshot", [unnamed.arguments, 64, 0.3], showing.chatId)
        guard current() else { return }
        if response["success"] as? Bool != true, Self.isGone(response["error"] as? String) {
            targets.removeAll { $0 == unnamed }
            automaticTargets[showing.chatId]?.remove(unnamed)
            onSimulatorGone?(showing.chatId, unnamed.udid)
            return
        }
        guard response["success"] as? Bool == true, let frame = response["result"] as? [String: Any],
              let name = frame["name"] as? String, !name.isEmpty, names[unnamed.udid] == nil else { return }
        names[unnamed.udid] = name
    }

    func updateLiveGeometry(pointSize: CGSize, chrome nextChrome: SimulatorDisplayChrome?) {
        if pointSize.width > 0, pointSize.height > 0, logicalScreenSize != pointSize {
            logicalScreenSize = pointSize
        }
        if let nextChrome, chrome != nextChrome {
            chrome = nextChrome
        }
    }

    func setAllowed(_ value: Bool) {
        guard allowed != value else { return }
        allowed = value
        // Hidden under a sheet or the keyboard's own screen: the live video stops too.
        if !value { live = false; maximized = false }
    }

    /// What a failed request means to the person looking at it.
    static func explain(_ error: String?) -> String {
        guard let error, !error.isEmpty else {
            return "The Mac could not provide a preview. Check its connection, then retry."
        }
        // A Mac from before simulatorSnapshot: its host doesn't know the method,
        // its web view doesn't allow it, or its Direct policy doesn't list it.
        if error.contains("Unknown method") || error.contains("NOT_ALLOWED") || error.contains("not available through Direct") {
            return "Update Ripul on the Mac to see its simulators here."
        }
        return error
    }

    private func resetFrame() {
        lastJPEG = nil
        if frame.image != nil { frame.image = nil }
        if imageSize != .zero { imageSize = .zero }
        if logicalScreenSize != .zero { logicalScreenSize = .zero }
        if chrome != nil { chrome = nil }
    }

    private enum PreviewError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

private struct SimulatorPreviewImage: View {
    @ObservedObject var frame: HostScreenPreviewFrame
    let chrome: SimulatorDisplayChrome
    let viewportSize: CGSize
    var body: some View {
        SimulatorChromePreviewSurface(
            image: frame.image,
            chrome: chrome,
            viewportSize: viewportSize
        )
    }
}

@available(iOS 26.0, *)
struct SimulatorPreviewPanel: View {
    @ObservedObject var state: SimulatorPreviewState
    /// Where the panel keeps its place and size: the chat's, or the floated one's.
    var storageKey = "ripul.simulatorPreview"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88) }

    var body: some View {
        GeometryReader { geometry in
            // The docked simulator is the dock's: its panel stays away until it leaves.
            if let selection = state.selection, !state.isDocked {
                let ratio = state.chassisAspectRatio
                // The picture's empty band above the simulator's frame goes under
                // the toolbar, so the toolbar sits `barGap` above the frame itself
                // (Peter, 3 November 2026: it sat too far from the simulator). The
                // panel locks the shape of the rest.
                let band = state.chassisTopBand
                let shape = ratio / (1 - band)
                let bar = Self.toolbarHeight
                let opening = min(geometry.size.width / 3, 300)
                // The buttons in a toolbar above the picture; two fingers resize
                // the pictures, and under Control they are the simulator's. It
                // moves anywhere in the window, over the chat's title and bottom
                // bar too (Peter, 3 November 2026), and is sized between them.
                RipulFloatingPanel(storageKey: storageKey, defaultSize: CGSize(width: opening, height: opening / shape + bar),
                    minSize: CGSize(width: 120, height: 120 / shape + bar), showsResizeGrip: !state.collapsed,
                    aspectRatio: shape, toolbarHeight: bar, contentInsets: UIEdgeInsets(top: 52, left: 0, bottom: 88, right: 0), avoidsKeyboard: true,
                    movesToWindowEdges: true, movesFromTopStrip: state.live ? bar : nil, keepsTrailingEdge: true,
                    pinchesToResize: !state.live && !state.collapsed) { size in
                    let width = min(size.width, geometry.size.width - 24, max(120, (geometry.size.height - 156 - bar) * shape))
                    let displaySize = CGSize(width: width, height: width / ratio)
                    let tucked = displaySize.height * band
                    let screenRect = SimulatorChromePath.screenRect(
                        in: displaySize,
                        screenSize: state.effectiveScreenSize,
                        chrome: state.effectiveChrome,
                        includesButtonPadding: true
                    )
                    let screenPadding = EdgeInsets(
                        top: max(6, screenRect.minY + 4),
                        leading: max(6, screenRect.minX + 4),
                        bottom: max(6, displaySize.height - screenRect.maxY + 4),
                        trailing: max(6, displaySize.width - screenRect.maxX + 4)
                    )
                    // Minimising shrinks the panel into its minimise button at the
                    // top-right, and expanding grows it back out (`keepsTrailingEdge`).
                    // Where the host keeps that button in its own chrome, the panel
                    // shrinks into its corner and leaves nothing behind.
                    FloatingPanelCollapse(collapsed: state.collapsed, expanded: CGSize(width: width, height: width / shape + bar),
                                          button: state.buttonHosted ? 0 : 56, animation: spring) {
                        VStack(spacing: 0) {
                            // Over the picture's band: a finger on the bar, or in the
                            // gap under it, moves the panel and never reaches the live
                            // picture beneath.
                            toolbar(width: width, showing: selection.target)
                                .zIndex(1)
                            Color.clear
                                .frame(width: width, height: Self.barGap)
                                .contentShape(.interaction, Rectangle())
                                .zIndex(1)
                            ZStack {
                                if state.live && !state.maximized, let liveContent = state.liveContent {
                                    // The person's fingers go to the simulator; the panel moves from its toolbar.
                                    liveContent(selection.target.udid, selection.machineId)
                                        .accessibilityIdentifier("SimulatorPreview.live")
                                } else {
                                    SimulatorPreviewImage(
                                        frame: state.frame,
                                        chrome: state.effectiveChrome,
                                        viewportSize: state.effectiveScreenSize
                                    ).allowsHitTesting(false)
                                }
                                if !state.live, let error = state.error {
                                    VStack(spacing: 8) {
                                        Text(error).ripulText().font(.ripul(.caption)).multilineTextAlignment(.center) // theme-mapping: the error text unchanged, moved under the toolbar
                                        Button("Retry") { state.retry() }.buttonStyle(.bordered)
                                    }
                                    .padding(8)
                                    .padding(screenPadding)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else if !state.live, state.imageSize == .zero {
                                    ProgressView()
                                        .padding(screenPadding)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .accessibilityLabel("Connecting to Simulator")
                                }
                                if let notice = state.notice {
                                    Text(notice).ripulText().font(.ripul(.caption)).multilineTextAlignment(.center) // theme-mapping: a control's notice, set as the panel's error text
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .glassEffect(.clear, in: Capsule())
                                        .padding(.horizontal, screenPadding.leading)
                                        .padding(.bottom, screenPadding.bottom + 8)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                        .allowsHitTesting(false)
                                        .accessibilityIdentifier("SimulatorPreview.notice")
                                }
                            }
                            .frame(width: width, height: displaySize.height)
                            .padding(.top, -tucked)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("SimulatorPreview.picture")
                        }
                        .frame(width: width, height: width / shape + bar)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(state.title)
                        .accessibilityIdentifier("SimulatorPreview.surface")
                        .onChange(of: width, initial: true) { _, points in
                            state.pictureWidth = SimulatorPreviewState.pictureWidth(points: points, scale: displayScale)
                        }
                    } minimised: {
                        if !state.buttonHosted {
                            control("pip", label: "Expand simulator preview", id: "expand", diameter: 56, iconSize: 22) { state.collapsed = false }
                                .contextMenu { MenuIcons {
                                    Button { state.collapsed = false } label: { Label("Expand Simulator", systemImage: "pip.exit") }
                                    if state.canMaximize {
                                        Button { state.maximize() } label: { Label("Maximize Simulator", systemImage: "arrow.up.left.and.arrow.down.right") }
                                    }
                                    if state.floatWindow != nil {
                                        Button { state.floatOut() } label: { Label("Float in New Window", systemImage: "macwindow.badge.plus") }
                                    }
                                    if state.closeDismisses {
                                        Button(role: .destructive) { state.close() } label: { Label("Close Simulator", systemImage: "xmark") }
                                    }
                                }}
                                .clipShape(Circle())
                                .glassEffect(.clear, in: Circle())
                                .shadow(color: Color.ripul(system: .black).opacity(0.2), radius: 10, y: 3) // theme-mapping: the panel's shadow unchanged, now on the panel and on its minimised button apart
                        }
                    }
                }
                .docking(dockOffer)
                .onGesture { [state] in state.gestureHoldsButtons = $0 }
            }
        }
        .ignoresSafeArea(.container)
        .fullScreenCover(
            isPresented: Binding(
                get: { state.maximized && state.selection != nil && state.canMaximize },
                set: { if !$0 { state.restoreFromMaximize() } }
            )
        ) {
            if let selection = state.selection {
                fullScreenView(for: selection)
            }
        }
    }

    /// Into the window's right edge: the dock, where the window has one and the
    /// host can show the simulator live. Read as the drag happens, so a dock
    /// that joins after the panel was drawn still counts.
    private var dockOffer: FloatingPanelDocking {
        FloatingPanelDocking(
            canDock: { [state] width in state.canMaximize && (state.dock?.canDock(containerWidth: width) ?? false) },
            hover: { [state] over in state.dock?.hover(.simulator, over, screen: state.effectiveScreenSize) },
            drop: { [state] in state.dockIntoWindow() })
    }

    private func fullScreenView(for selection: SimulatorPreviewState.Selection) -> some View {
        ZStack {
            Color.ripul(system: .black).ignoresSafeArea()
            if let presentation = state.fullScreenPresentation {
                presentation(selection.target.udid, selection.machineId, fullScreenControls(for: selection))
                    .id("\(selection.machineId)-\(selection.target.udid)-\(state.fullScreenGeneration)")
                    .ignoresSafeArea(.container)
            } else if let content = state.fullScreenContent ?? state.liveContent {
                content(selection.target.udid, selection.machineId)
                    .id("\(selection.machineId)-\(selection.target.udid)-\(state.fullScreenGeneration)")
                    .ignoresSafeArea(.container)
            }
        }
        .overlay(alignment: .top) {
            if state.fullScreenPresentation == nil {
                legacyFullScreenControls(for: selection)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = state.notice {
                Text(notice)
                    .font(.ripul(.caption))
                    .padding(12)
                    .glassEffect(.clear, in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden()
        // Auto-hiding the Home indicator gives the system's Home gesture
        // priority over the edge deferral below. This is an interactive surface.
        .persistentSystemOverlays(.visible)
        .defersSystemGestures(on: .all)
        .ignoresSafeArea(.keyboard)
        .interactiveDismissDisabled()
        .accessibilityAction(.escape) { state.restoreFromMaximize() }
        .uiKitIdentifier("SimulatorPreview.fullScreen")
    }

    private func legacyFullScreenControls(for selection: SimulatorPreviewState.Selection) -> some View {
        HStack {
            Menu {
                MenuIcons {
                    ForEach(state.hardwareControls) { item in
                        Button { Task { await state.control(item.action) } } label: { Label(item.title, systemImage: item.symbol) }
                    }
                    if state.foldable {
                        Divider()
                        ForEach(SimulatorPreviewState.foldControls) { item in
                            Button { Task { await state.control(item.action) } } label: { Label(item.title, systemImage: item.symbol) }
                        }
                    }
                    if state.targets.count > 1 {
                        Divider()
                        ForEach(state.targets, id: \.udid) { target in
                            Button {
                                state.switchTo(target)
                            } label: {
                                if target == selection.target {
                                    Label(name(of: target), systemImage: "checkmark")
                                } else {
                                    Text(name(of: target))
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.ripulIcon(size: 16, weight: .semibold))
                    .foregroundStyle(.ripul(.text))
                    .frame(width: 40, height: 40)
                    .glassEffect(.clear.interactive(), in: Circle())
            }
            .accessibilityLabel("Simulator Controls")
            .uiKitIdentifier("SimulatorPreview.fullScreen.controls")

            Spacer()

            Button { state.restoreFromMaximize() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.ripulIcon(size: 16, weight: .semibold))
                    .foregroundStyle(.ripul(.text))
                    .frame(width: 40, height: 40)
                    .glassEffect(.clear.interactive(), in: Circle())
            }
            .accessibilityLabel("Restore Simulator View")
            .uiKitIdentifier("SimulatorPreview.fullScreen.restore")
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private func fullScreenControls(for selection: SimulatorPreviewState.Selection) -> SimulatorFullScreenControls {
        let hardware = state.hardwareControls + (state.foldable ? SimulatorPreviewState.foldControls : [])
        let actions = hardware.map { item in
            SimulatorFullScreenControls.Action(id: item.action, title: item.title, symbol: item.symbol,
                perform: { Task { await state.control(item.action) } })
        }
        let simulatorMenu: UIMenu? = state.targets.count > 1 ? UIMenu(title: "Simulators", children: state.targets.map { target in
            UIAction(title: name(of: target), state: target == selection.target ? .on : .off) { _ in state.switchTo(target) }
        }) : nil
        return SimulatorFullScreenControls(screenSize: state.effectiveScreenSize, actions: actions,
                                           simulatorMenu: simulatorMenu, restore: { state.restoreFromMaximize() })
    }

    // MARK: The toolbar

    /// The toolbar above the picture: its bar, the gap under it to the
    /// simulator's frame, each button's width in it, its icons, and the room
    /// the simulator's name needs. Half as big again as it was (Peter, 3
    /// November 2026).
    static let barHeight: CGFloat = 45
    static let barGap: CGFloat = 3
    static var toolbarHeight: CGFloat { barHeight + barGap }
    static let toolWidth: CGFloat = 42
    static let barPadding: CGFloat = 6
    static let iconSize: CGFloat = 19.5
    static let titleRoom: CGFloat = 66

    /// The toolbar's buttons, in the order the bar draws them. Close and the
    /// menu lead; Home (under Control), the window button, Control and
    /// Minimise trail.
    enum Tool: Int, CaseIterable {
        case close, menu, home, window, control, minimise
        var leads: Bool { self == .close || self == .menu }
    }

    /// What gives way when the bar is narrow, first to last: each is in the
    /// menu too (Maximize, Float, Home), or does what Minimise does (Close).
    static let givesWay: [Tool] = [.window, .close, .home]

    /// The buttons a bar `width` points wide holds, of those `available`.
    static func tools(_ available: [Tool], width: CGFloat) -> [Tool] {
        var tools = available
        for tool in givesWay where CGFloat(tools.count) * toolWidth + 2 * barPadding > width {
            tools.removeAll { $0 == tool }
        }
        return tools
    }

    /// Each of `count` buttons' width in a bar `width` points wide: its own
    /// where they fit, and an equal share of the bar where even those that
    /// never give way (the menu, Control and Minimise) don't.
    static func buttonWidth(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return toolWidth }
        return min(toolWidth, max(0, width - 2 * barPadding) / CGFloat(count))
    }

    private var availableTools: [Tool] {
        Tool.allCases.filter { tool in
            switch tool {
            case .close, .menu, .minimise: return true
            case .home: return state.live
            case .window: return state.floatWindow != nil || state.canMaximize
            case .control: return state.liveContent != nil
            }
        }
    }

    /// The panel's buttons, in a bar of their own above the picture (Peter, 2
    /// November 2026: glass buttons cut into the picture's frame didn't work
    /// well). The simulator's name sits between them where there is room;
    /// with several simulators it switches between them, as the … menu does.
    private func toolbar(width: CGFloat, showing: SimulatorTarget) -> some View {
        let tools = Self.tools(availableTools, width: width)
        let toolWidth = Self.buttonWidth(count: tools.count, width: width)
        let room = width - 2 * Self.barPadding - CGFloat(tools.count) * toolWidth
        return HStack(spacing: 0) {
            ForEach(tools.filter(\.leads), id: \.self) { barButton($0, showing: showing, width: toolWidth) }
            if room >= Self.titleRoom {
                title(showing: showing)
            } else {
                Spacer(minLength: 0)
            }
            ForEach(tools.filter { !$0.leads }, id: \.self) { barButton($0, showing: showing, width: toolWidth) }
        }
        .padding(.horizontal, Self.barPadding)
        .frame(width: width, height: Self.barHeight)
        .contentShape(.interaction, Rectangle())
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SimulatorPreview.toolbar")
    }

    @ViewBuilder
    private func barButton(_ tool: Tool, showing: SimulatorTarget, width: CGFloat) -> some View {
        switch tool {
        case .close:
            barTool("xmark", label: "Close simulator preview", id: "close", width: width) {
                if state.closeDismisses {
                    state.close()
                } else {
                    state.live = false
                    state.collapsed = true
                }
            }
        case .menu:
            toolsMenu(showing: showing, width: width)
        case .home:
            barTool("house", label: "Home", id: "home", width: width) { Task { await state.control("home") } }
        case .window:
            if state.floatWindow != nil {
                barTool("macwindow.badge.plus", label: "Float simulator in new window", id: "float", width: width) { state.floatOut() }
            } else {
                barTool("arrow.up.left.and.arrow.down.right", label: "Maximize simulator", id: "maximize", width: width) { state.maximize() }
            }
        case .control:
            if state.live {
                barTool("hand.raised.slash", label: "Stop controlling the simulator", id: "watch", width: width) { state.setLive(false) }
            } else {
                barTool("hand.point.up.left", label: "Control the simulator", id: "control", width: width) { state.setLive(true) }
            }
        case .minimise:
            barTool("minus", label: "Minimise simulator preview", id: "minimize", width: width) {
                state.live = false
                state.collapsed = true
            }
        }
    }

    /// A button in the toolbar, `width` points wide. It ignores a press while
    /// one of the panel's own gestures has it: a drag of the panel by its
    /// toolbar, or a pinch begun on a button, isn't a press of the button it
    /// began on.
    private func barTool(_ symbol: String, label: String, id: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button { if !state.gestureHoldsButtons { action() } } label: {
            Image(systemName: symbol)
                .font(.ripulIcon(size: Self.iconSize, weight: .semibold)) // theme-mapping: the panel's buttons' icons, now in its toolbar at one size
                .foregroundStyle(.ripul(.text)) // theme-mapping: the panel's buttons' icons, unchanged colour
                .frame(width: width, height: Self.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .uiKitIdentifier("SimulatorPreview.\(id)")
    }

    /// The simulator's hardware, as its Mac offers it: Home, the app switcher,
    /// rotating, and opening or closing a foldable; with several simulators,
    /// the switch between them (not while driving, which switching would stop).
    private func toolsMenu(showing: SimulatorTarget, width: CGFloat) -> some View {
        Menu {
            MenuIcons {
                if state.canMaximize {
                    Button { state.maximize() } label: { Label("Maximize Simulator", systemImage: "arrow.up.left.and.arrow.down.right") }
                }
                if state.floatWindow != nil {
                    Button { state.floatOut() } label: { Label("Float in New Window", systemImage: "macwindow.badge.plus") }
                }
                if state.canMaximize || state.floatWindow != nil {
                    Divider()
                }
                ForEach(state.hardwareControls) { item in
                    Button { Task { await state.control(item.action) } } label: { Label(item.title, systemImage: item.symbol) }
                }
                if state.foldable {
                    Divider()
                    ForEach(SimulatorPreviewState.foldControls) { item in
                        Button { Task { await state.control(item.action) } } label: { Label(item.title, systemImage: item.symbol) }
                    }
                }
                if !state.live, state.targets.count > 1 {
                    Divider()
                    simulatorChoices(showing: showing)
                }
                // A floated panel's Close gives way first on a narrow bar.
                if state.closeDismisses {
                    Divider()
                    Button(role: .destructive) { state.close() } label: { Label("Close Simulator", systemImage: "xmark") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.ripulIcon(size: Self.iconSize, weight: .semibold)) // theme-mapping: the menu's icon, now in the toolbar at one size
                .foregroundStyle(.ripul(.text))
                .frame(width: width, height: Self.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Simulator controls")
        .uiKitIdentifier("SimulatorPreview.controls")
    }

    /// The simulator's name in the toolbar; with several simulators, the
    /// switch between them.
    @ViewBuilder
    private func title(showing: SimulatorTarget) -> some View {
        if !state.live, state.targets.count > 1 {
            Menu {
                MenuIcons { simulatorChoices(showing: showing) }
            } label: {
                HStack(spacing: 4) {
                    Text(name(of: showing)).ripulText().font(.ripul(.body)).lineLimit(1) // theme-mapping: the switch's label, half as big again as the panel's error text
                    Image(systemName: "chevron.up.chevron.down").font(.ripulIcon(.callout)).foregroundStyle(.ripul(.text)) // theme-mapping: its chevron, a step under its text
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch simulator")
            .accessibilityValue(name(of: showing))
            .uiKitIdentifier("SimulatorPreview.switch")
        } else {
            Text(name(of: showing)).font(.ripul(.body)).foregroundStyle(.ripul(.textSecondary)).lineLimit(1) // theme-mapping: a new title, half as big again with the toolbar
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("SimulatorPreview.title")
        }
    }

    /// The chat's simulators, by the names their Mac gave them.
    @ViewBuilder
    private func simulatorChoices(showing: SimulatorTarget) -> some View {
        ForEach(state.targets, id: \.udid) { target in
            Button {
                state.switchTo(target)
            } label: {
                if target == showing {
                    Label(name(of: target), systemImage: "checkmark")
                } else {
                    Text(name(of: target))
                }
            }
        }
    }

    private func name(of target: SimulatorTarget) -> String {
        state.names[target.udid] ?? "Simulator \(target.udid.prefix(8))"
    }

    /// A round glass button drawn at `diameter` points across.
    private func control(_ symbol: String, label: String, id: String, diameter: CGFloat = 34, iconSize: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button { if !state.gestureHoldsButtons { action() } } label: {
            Image(systemName: symbol)
                .font(.ripulIcon(size: iconSize, weight: .semibold))
                .foregroundStyle(.ripul(.text))
                .frame(width: diameter, height: diameter)
                .glassEffect(.clear.interactive(), in: Circle())
        }
        .frame(width: diameter, height: diameter)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .uiKitIdentifier("SimulatorPreview.\(id)")
    }
}

@available(iOS 26.0, *)
final class SimulatorPreviewController: UIViewController {
    let state: SimulatorPreviewState
    let invoke: SimulatorPreviewState.Invoke
    private var updates: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()
    private var appeared = false
    private var requested = false
    private let storageKey: String
    init(state: SimulatorPreviewState, storageKey: String = "ripul.simulatorPreview",
         invoke: @escaping SimulatorPreviewState.Invoke) {
        self.state = state; self.invoke = invoke; self.storageKey = storageKey
        state.invoke = invoke
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = HostScreenPreviewPassthroughView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SimulatorPreviewPanel(state: state, storageKey: storageKey).ripulThemeRoot())
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view)
        host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        state.$selection.combineLatest(state.$collapsed, state.$allowed, state.$live)
            .combineLatest(state.$maximized, state.$dockedUdid)
            .sink { [weak self] combined, maximized, dockedUdid in
                let (selection, collapsed, allowed, live) = combined
                // Docked, the dock's live picture replaces the stills.
                self?.requested = selection != nil && !collapsed && allowed && !live && !maximized
                    && !SimulatorPreviewState.isDocked(selection, dockedUdid: dockedUdid)
                self?.syncCapture()
            }.store(in: &observations)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                if notification.name == UIApplication.willResignActiveNotification { self?.stopCapture() }
                else { self?.syncCapture() }
            }.store(in: &observations)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        syncCapture()
    }
    private func stopCapture() { updates?.cancel(); updates = nil }
    private func syncCapture() {
        guard appeared, requested, UIApplication.shared.applicationState == .active else { stopCapture(); return }
        guard updates == nil else { return }
        updates = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.visible, UIApplication.shared.applicationState == .active {
                    await self.state.refresh(invoke: self.invoke)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private var visible: Bool {
        guard view.window != nil else { return false }
        var ancestor: UIView? = view
        while let next = ancestor {
            if next.isHidden || next.alpha < 0.01 { return false }
            ancestor = next.superview
        }
        return true
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false; stopCapture() }
    deinit { updates?.cancel() }
}

@available(iOS 26.0, *)
private struct SimulatorPreviewOverlay: UIViewControllerRepresentable {
    let bridge: AgentBridge
    func makeUIViewController(context: Context) -> SimulatorPreviewController {
        SimulatorPreviewController(state: bridge.simulatorPreview) { [weak bridge] machineId, method, args, chatId in
            guard let bridge else { return ["success": false] }
            return await bridge.mirrorInvoke(machineId: machineId, capability: "screenWindows", method: method, args: args, chatId: chatId)
        }
    }
    func updateUIViewController(_ controller: SimulatorPreviewController, context: Context) {
        controller.state.liveContent = bridge.simulatorLiveContent
        controller.state.fullScreenContent = bridge.simulatorFullScreenContent
        controller.state.fullScreenPresentation = bridge.simulatorFullScreenPresentation
        controller.state.floatWindow = bridge.simulatorFloatWindow
        controller.state.onSimulatorGone = { [weak bridge] chatId, udid in
            bridge?.reportSimulatorGoneToWeb(chatId: chatId, udid: udid)
        }
        controller.state.setAllowed(!bridge.suppressNativeChatInput)
        // Another chat: this one's panel is put away, and that one's comes back.
        let activeChatId = bridge.currentSourceChatId ?? (bridge.nativeChatScrollerEnabled ? bridge.nativeChat.currentChatId : nil)
        controller.state.show(chatId: activeChatId)
    }
}

struct SimulatorPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    var shown = true
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.overlay { if shown { SimulatorPreviewOverlay(bridge: bridge).ignoresSafeArea(.container) } }
        } else { content }
    }
}

/// The simulator floated out of the Simulators screen (`AgentBridge.floatSimulator`):
/// a panel of its own, which no chat owns, over every screen until its Close.
/// It keeps its own place and size, and docks as a chat's panel does: out of
/// the dock it comes back here (`AgentBridge.joinPreviewDock`).
@available(iOS 26.0, *)
private struct FloatedSimulatorOverlay: UIViewControllerRepresentable {
    let bridge: AgentBridge
    func makeUIViewController(context: Context) -> SimulatorPreviewController {
        SimulatorPreviewController(state: bridge.floatedSimulatorPreview, storageKey: "ripul.floatedSimulator") { [weak bridge] machineId, method, args, _ in
            guard let bridge else { return ["success": false] }
            return await bridge.mirrorInvoke(machineId: machineId, capability: "screenWindows", method: method, args: args)
        }
    }
    func updateUIViewController(_ controller: SimulatorPreviewController, context: Context) {
        controller.state.liveContent = bridge.simulatorLiveContent
        controller.state.fullScreenContent = bridge.simulatorFullScreenContent
        controller.state.fullScreenPresentation = bridge.simulatorFullScreenPresentation
        controller.state.floatWindow = bridge.simulatorFloatWindow
        controller.state.setAllowed(!bridge.suppressNativeChatInput)
    }
}

struct FloatedSimulatorPresenter: ViewModifier {
    let bridge: AgentBridge
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.overlay { FloatedSimulatorOverlay(bridge: bridge).ignoresSafeArea(.container) }
        } else { content }
    }
}
#else
import SwiftUI
struct SimulatorPreviewPresenter: ViewModifier {
    let bridge: AgentBridge
    var shown = true
    func body(content: Content) -> some View { content }
}
#endif

private struct PreviewPanelsAtWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The host app shows the chat's preview panels over its whole window.
    var ripulPreviewPanelsAtWindow: Bool {
        get { self[PreviewPanelsAtWindowKey.self] }
        set { self[PreviewPanelsAtWindowKey.self] = newValue }
    }
}

public extension View {
    /// The chat's picture-in-picture panels (the simulator's and the
    /// browser's) over this whole view, the window, rather than over the
    /// chat's own area, so they can be moved anywhere in it: on a Mac, or on
    /// a wide phone, the chat is one column of several. The chat inside then
    /// leaves them out. `shown` is whether a chat is on screen; the panels
    /// belong to it, and go while another screen is.
    ///
    /// In a window laid out with `RipulPreviewDockLayout`, either panel docks
    /// into the window's right edge when dragged there.
    ///
    /// A simulator floated from the Simulators screen (`AgentBridge.floatSimulator`)
    /// belongs to no chat: its panel shows whatever `shown` is, above the chat's.
    func ripulPreviewPanels(bridge: AgentBridge, shown: Bool) -> some View {
        #if os(iOS)
        // The dock's indicator first, so the panel being dragged stays over it.
        environment(\.ripulPreviewPanelsAtWindow, true)
            .modifier(PreviewDockPresenter(bridge: bridge))
            .modifier(SimulatorPreviewPresenter(bridge: bridge, shown: shown))
            .modifier(BrowserPreviewPresenter(bridge: bridge, shown: shown))
            .modifier(FloatedSimulatorPresenter(bridge: bridge))
        #else
        environment(\.ripulPreviewPanelsAtWindow, true)
            .modifier(SimulatorPreviewPresenter(bridge: bridge, shown: shown))
            .modifier(BrowserPreviewPresenter(bridge: bridge, shown: shown))
        #endif
    }
}
