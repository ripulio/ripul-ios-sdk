#if os(iOS)
import XCTest
import UIKit
import SwiftUI
import Combine
@testable import RipulAgent

@MainActor
final class SimulatorPreviewTests: XCTestCase {
    private let target = SimulatorTarget(udid: "08E561AA-A868-4196-AF4A-3501D80DF965")
    private func frame(_ color: UIColor = .blue, appearance: [String: Any]? = nil, name: String = "iPhone 17") -> [String: Any] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }
        var result: [String: Any] = ["name": name, "jpegB64": image.jpegData(compressionQuality: 0.5)!.base64EncodedString()]
        if let appearance { result["appearance"] = appearance }
        return ["success": true, "result": result]
    }
    /// docs/architecture/androidEmulators.md: an AVD's UDID is version 8, and its panel has Android's buttons.
    func testAnAndroidEmulatorIsToldByItsUDIDAndGetsBackHomeAndRecents() {
        XCTAssertTrue(AndroidEmulatorUDID.isAndroid("FDA04436-8935-86E7-AE08-D7AC01F0B184"))
        XCTAssertFalse(AndroidEmulatorUDID.isAndroid(target.udid))
        XCTAssertFalse(AndroidEmulatorUDID.isAndroid("emulator-5554"))
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        XCTAssertEqual(state.hardwareControls.map(\.action), ["home", "appSwitcher", "rotateLeft", "rotateRight"])
        state.open(SimulatorTarget(udid: "FDA04436-8935-86E7-AE08-D7AC01F0B184"), machineId: "host", chatId: "chat")
        XCTAssertEqual(state.hardwareControls.map(\.action), ["back", "home", "appSwitcher", "rotateLeft", "rotateRight"])
        XCTAssertEqual(state.hardwareControls.first(where: { $0.action == "appSwitcher" })?.title, "Recents")
    }

    func testDuplicateFramesDoNotDecodeOrInvalidatePanel() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        let sameFrame = frame()
        let invoke: SimulatorPreviewState.Invoke = { _, _, _, _ in sameFrame }
        await state.refresh(invoke: invoke)
        let first = state.image
        XCTAssertEqual(state.title, "iPhone 17")
        var panelUpdates = 0
        var frameUpdates = 0
        let panel = state.objectWillChange.sink { panelUpdates += 1 }
        let image = state.frame.objectWillChange.sink { frameUpdates += 1 }
        defer { panel.cancel(); image.cancel() }
        for _ in 0..<100 {
            state.setAllowed(true)
            await state.refresh(invoke: invoke)
        }
        XCTAssertTrue(first === state.image)
        XCTAssertEqual(panelUpdates, 0)
        XCTAssertEqual(frameUpdates, 0)
        // A new picture of the same shape should invalidate only the image leaf.
        let changed = frame(.red)
        await state.refresh { _, _, _, _ in changed }
        XCTAssertEqual(frameUpdates, 1)
        XCTAssertEqual(panelUpdates, 0)
    }

    func testAsksTheOwningHostForTheSimulatorItselfAndPausesWhileCollapsedOrHidden() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "original-host", chatId: "chat")
        var methods: [String] = []
        let invoke: SimulatorPreviewState.Invoke = { machine, method, args, chat in
            XCTAssertEqual(machine, "original-host")
            XCTAssertEqual(chat, "chat")
            XCTAssertEqual((args.first as? [String: Any])?["udid"] as? String, self.target.udid)
            XCTAssertEqual(args[1] as? Int, 640)
            methods.append(method)
            return self.frame()
        }
        await state.refresh(invoke: invoke)
        XCTAssertNotNil(state.image)
        state.collapsed = true
        await state.refresh(invoke: invoke)
        XCTAssertEqual(methods, ["simulatorSnapshot"])
        state.collapsed = false; state.allowed = false
        await state.refresh(invoke: invoke)
        XCTAssertEqual(methods.count, 1)
        state.allowed = true
        await state.refresh(invoke: invoke)
        XCTAssertEqual(methods, ["simulatorSnapshot", "simulatorSnapshot"])
    }

    func testAutomaticOpensKeepTheMinimiseAndTheSimulatorShowing() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertFalse(state.collapsed)
        await state.refresh { _, _, _, _ in self.frame() }
        let shown = state.image
        state.collapsed = true
        // The agent reaches for the same simulator again: nothing moves.
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertTrue(state.collapsed)
        XCTAssertTrue(state.image === shown)
        // Another simulator in the same chat follows, still minimised.
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.open(other, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertEqual(state.selection?.target, other)
        XCTAssertTrue(state.collapsed)
        XCTAssertNil(state.image)
        // The person asking always shows it.
        state.open(other, machineId: "host", chatId: "chat")
        XCTAssertFalse(state.collapsed)
        // After Close, the agent's next reach opens it again, expanded.
        state.close()
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertNotNil(state.selection)
        XCTAssertFalse(state.collapsed)
    }

    func testClosingOrReplacingTargetDiscardsDelayedFramesAndPreventsOverlap() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        var pending: CheckedContinuation<[String: Any], Never>?
        let task = Task {
            await state.refresh { _, _, _, _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await state.refresh { _, _, _, _ in XCTFail("Overlapping capture"); return [:] }
        state.close()
        state.show(chatId: "another-chat")
        state.open(target, machineId: "different-host", chatId: "another-chat")
        pending?.resume(returning: frame())
        await task.value
        XCTAssertNil(state.image)
        XCTAssertEqual(state.title, "Simulator")
        XCTAssertEqual(state.selection?.machineId, "different-host")
    }

    func testEachChatKeepsItsPanelWhileAnotherShows() async {
        let state = SimulatorPreviewState()
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.show(chatId: "a")
        state.open(target, machineId: "host", chatId: "a", automatic: true)
        state.collapsed = true
        state.show(chatId: "b")
        XCTAssertNil(state.selection)
        state.open(other, machineId: "host", chatId: "b", automatic: true)
        XCTAssertEqual(state.selection?.target, other)
        XCTAssertFalse(state.collapsed)
        // Back to the first chat: its simulator, minimised as it was left.
        state.show(chatId: "a")
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertEqual(state.selection?.chatId, "a")
        XCTAssertTrue(state.collapsed)
        // Closed stays closed when the chat comes round again.
        state.show(chatId: "b")
        XCTAssertEqual(state.selection?.target, other)
        state.close()
        state.show(chatId: "a")
        state.show(chatId: "b")
        XCTAssertNil(state.selection)
    }

    func testAChatOutOfSightGetsItsPanelForLater() {
        let state = SimulatorPreviewState()
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.show(chatId: "a")
        state.open(target, machineId: "host", chatId: "b", automatic: true)
        state.open(other, machineId: "host", chatId: "b", automatic: true)
        // Re-sending the first target automatically does not rewind selection back to it.
        state.open(target, machineId: "host", chatId: "b", automatic: true)
        XCTAssertNil(state.selection)
        state.show(chatId: "b")
        XCTAssertEqual(state.selection?.target, other)
        XCTAssertEqual(state.targets, [target, other])
        XCTAssertEqual(state.selection?.machineId, "host")
    }

    func testEvictsDeletedAutomaticSimulatorsAndKeepsManualError() async {
        let gone = "This simulator is no longer available in the tool call's Xcode installation."
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        let state = SimulatorPreviewState()
        var reportedGone: [(String, String)] = []
        state.onSimulatorGone = { reportedGone.append(($0, $1)) }

        // 1. Both a live simulator and a deleted automatic simulator in the chat:
        //    refreshing the deleted one drops it and switches straight to the live one.
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        state.open(other, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertEqual(state.selection?.target, other)
        await state.refresh { _, _, args, _ in
            let udid = (args.first as? [String: Any])?["udid"] as? String
            if udid == other.udid {
                return ["success": false, "error": gone]
            }
            return self.frame(name: "iPhone Duo")
        }
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertEqual(state.targets, [target])
        XCTAssertEqual(state.title, "iPhone Duo")
        XCTAssertNil(state.error)
        XCTAssertEqual(reportedGone.map(\.1), [other.udid])

        // 2. When the only automatic simulator is deleted, the panel closes instead of stuck error.
        await state.refresh { _, _, _, _ in ["success": false, "error": gone] }
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.targets, [])
        XCTAssertNil(state.error)

        // 3. When the person explicitly tapped View Simulator (automatic: false),
        //    the panel stays open and explains that the simulator is gone.
        state.open(other, machineId: "host", chatId: "chat", automatic: false)
        await state.refresh { _, _, _, _ in ["success": false, "error": gone] }
        XCTAssertEqual(state.selection?.target, other)
        XCTAssertEqual(state.error, gone)
    }

    func testForgettingADeletedSimulatorSwitchesOrCloses() {
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        let state = SimulatorPreviewState()
        state.show(chatId: "a")
        state.open(target, machineId: "host", chatId: "a", automatic: true)
        state.open(other, machineId: "host", chatId: "a", automatic: true)
        state.open(target, machineId: "host", chatId: "b", automatic: true)

        state.forget(udid: other.udid.lowercased(), chatId: "a")
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertEqual(state.targets, [target])

        state.forget(udid: target.udid, chatId: "a")
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.targets, [])

        // Background chat 'b' also drops its deleted simulator.
        state.forget(udid: target.udid, chatId: "b")
        state.show(chatId: "b")
        XCTAssertNil(state.selection)
    }

    func testSwitchesBetweenTheChatsSimulators() async {
        let state = SimulatorPreviewState()
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        await state.refresh { _, _, _, _ in self.frame(name: "iPhone Air") }
        state.open(other, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertEqual(state.targets, [target, other])
        XCTAssertEqual(state.selection?.target, other)
        XCTAssertEqual(state.names[target.udid], "iPhone Air")
        state.switchTo(target)
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertEqual(state.title, "iPhone Air")
        XCTAssertNil(state.image)
    }

    func testTheSwitchLearnsTheNamesOfSimulatorsNotYetShown() async {
        let state = SimulatorPreviewState()
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        state.open(other, machineId: "host", chatId: "chat", automatic: true)
        var asked: [String] = []
        var widths: [Int] = []
        let invoke: SimulatorPreviewState.Invoke = { _, _, args, _ in
            let udid = (args.first as? [String: Any])?["udid"] as? String ?? ""
            asked.append(udid); widths.append(args[1] as? Int ?? 0)
            return self.frame(name: udid == other.udid ? "iPhone Air" : "iPhone 17")
        }
        await state.refresh(invoke: invoke)
        XCTAssertEqual(asked, [other.udid, target.udid])
        XCTAssertEqual(widths, [640, 64])
        XCTAssertEqual(state.names[target.udid], "iPhone 17")
        XCTAssertEqual(state.title, "iPhone Air")
        // Asked once: later refreshes ask for the picture only.
        asked = []
        await state.refresh(invoke: invoke)
        XCTAssertEqual(asked, [other.udid])
    }

    func testControlStaysOnThroughATurnAndComesBackAfterAFold() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        state.invoke = { _, _, _, _ in ["success": true] }
        state.foldSettles = .milliseconds(1)
        state.live = true
        await state.control("rotateLeft")
        XCTAssertTrue(state.live)
        await state.control("open")
        XCTAssertTrue(state.live)
        // Watching, a fold stays watching.
        state.live = false
        await state.control("close")
        XCTAssertFalse(state.live)
        // Closed meanwhile: Control doesn't come back.
        state.live = true
        state.foldSettles = .milliseconds(200)
        let folding = Task { await state.control("open") }
        try? await Task.sleep(for: .milliseconds(20))
        state.close()
        await folding.value
        XCTAssertFalse(state.live)
    }

    func testThePictureIsAsWideAsThePanelOnItsScreen() {
        XCTAssertEqual(SimulatorPreviewState.pictureWidth(points: 300, scale: 2), 600)
        XCTAssertEqual(SimulatorPreviewState.pictureWidth(points: 300, scale: 3), 900)
        XCTAssertEqual(SimulatorPreviewState.pictureWidth(points: 600, scale: 3), 900)
        XCTAssertEqual(SimulatorPreviewState.pictureWidth(points: 120, scale: 1), 320)
    }

    func testControlsAskTheMac() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        var asked: [(String, [Any])] = []
        state.invoke = { _, method, args, _ in asked.append((method, args)); return ["success": true] }
        state.live = true
        await state.control("home")
        XCTAssertEqual(asked.last?.0, "simulatorControl")
        XCTAssertEqual((asked.last?.1.last as? [String: Any])?["action"] as? String, "home")
        XCTAssertEqual((asked.last?.1.first as? [String: Any])?["udid"] as? String, target.udid)
        XCTAssertTrue(state.live)
        // An older Mac is asked to update.
        state.invoke = { _, _, _, _ in ["success": false, "error": "Unknown method 'simulatorControl' on capability 'screenWindows'"] }
        await state.control("appSwitcher")
        XCTAssertEqual(state.notice, "Update Ripul on the Mac to use simulator controls.")
    }

    func testOffersFoldingOnlyForAFoldable() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        var picture = frame()
        picture["result"] = (picture["result"] as! [String: Any]).merging(["foldable": true]) { $1 }
        await state.refresh { _, _, _, _ in picture }
        XCTAssertTrue(state.foldable)
        state.open(SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17"), machineId: "host", chatId: "chat")
        XCTAssertFalse(state.foldable)
    }

    func testNeverShowsTheSimulatorItRunsIn() {
        let state = SimulatorPreviewState()
        state.ownSimulatorUdid = target.udid.lowercased()
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        state.open(target, machineId: "host", chatId: "chat")
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.targets, [])
    }

    func testControllingPausesTheStillsAndKeepsTheSimulator() async {
        let state = SimulatorPreviewState()
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.open(target, machineId: "host", chatId: "chat")
        state.live = true
        await state.refresh { _, _, _, _ in XCTFail("No stills while live"); return [:] }
        // The agent reaches for another simulator: it waits in the switch.
        state.open(other, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertTrue(state.live)
        XCTAssertEqual(state.targets, [target, other])
        // The person asking for it moves there, back to the picture.
        state.open(other, machineId: "host", chatId: "chat")
        XCTAssertEqual(state.selection?.target, other)
        XCTAssertFalse(state.live)
        // Hidden under another screen, live stops.
        state.live = true
        state.setAllowed(false)
        XCTAssertFalse(state.live)
    }

    func testAfterAFailureAsksEveryFewSecondsAndHealsByItself() async {
        let state = SimulatorPreviewState()
        var now = Date(timeIntervalSince1970: 1_000)
        state.clock = { now }
        state.open(target, machineId: "host", chatId: "chat")
        await state.refresh { _, _, _, _ in ["success": false, "error": "Request timed out after 20000ms"] }
        XCTAssertEqual(state.error, "Request timed out after 20000ms")
        now += 2
        await state.refresh { _, _, _, _ in XCTFail("Too soon after a failure"); return [:] }
        // An automatic open of the same simulator doesn't retry by itself.
        state.open(target, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertNotNil(state.error)
        // The Mac is back, as after a restart.
        now += 4
        await state.refresh { _, _, _, _ in self.frame() }
        XCTAssertNotNil(state.image)
        XCTAssertNil(state.error)
        // Retry, or the person's own open, asks at once.
        await state.refresh { _, _, _, _ in ["success": false, "error": "This simulator is shut down. Boot it on the Mac, then retry."] }
        XCTAssertNotNil(state.error)
        state.open(target, machineId: "host", chatId: "chat")
        XCTAssertNil(state.error)
        var asked = false
        await state.refresh { _, _, _, _ in asked = true; return self.frame(.red) }
        XCTAssertTrue(asked)
    }

    func testAnOlderMacIsAskedToUpdate() async {
        for said in ["Unknown method 'simulatorSnapshot' on capability 'screenWindows'",
                     "NOT_ALLOWED: screenWindows.simulatorSnapshot is not reachable from a mirror",
                     "This operation is not available through Direct"] {
            let state = SimulatorPreviewState()
            state.open(target, machineId: "host", chatId: "chat")
            await state.refresh { _, _, _, _ in ["success": false, "error": said] }
            XCTAssertEqual(state.error, "Update Ripul on the Mac to see its simulators here.")
        }
    }

    func testAppearanceFollowsEachPictureAndItsAspectRatio() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        await state.refresh { _, _, _, _ in self.frame(appearance: ["cropPresetId": "simulator.display", "cornerRadiusFraction": 0.14]) }
        XCTAssertEqual(state.aspectRatio, 0.5, accuracy: 0.001) // The picture is 32x64.
        XCTAssertEqual(state.appearance?.cornerRadius(for: CGSize(width: 200, height: 400)) ?? -1, 28, accuracy: 0.001)
        XCTAssertEqual(state.appearance?.cornerRadius(for: CGSize(width: 400, height: 200)) ?? -1, 28, accuracy: 0.001)
        XCTAssertEqual(state.appearance?.cornerRadius(for: CGSize(width: 100, height: 200)) ?? -1, 14, accuracy: 0.001)
        await state.refresh { _, _, _, _ in self.frame(.green) } // A device without uniform corners has none.
        XCTAssertNil(state.appearance)
        state.close()
        XCTAssertNil(state.appearance)
        XCTAssertEqual(state.aspectRatio, 0.47, accuracy: 0.001)
    }

    func testAppearanceRejectsInvalidMetadataAndAllowsSquareCorners() {
        XCTAssertNil(WindowPreviewAppearance(nil))
        XCTAssertNil(WindowPreviewAppearance(["cropPresetId": "", "cornerRadiusFraction": 0.1]))
        for radius in [Double.nan, .infinity, -0.1, 0.6] {
            XCTAssertNil(WindowPreviewAppearance(["cropPresetId": "device", "cornerRadiusFraction": radius]))
        }
        XCTAssertEqual(WindowPreviewAppearance(["cropPresetId": "device", "cornerRadiusFraction": 0.0])?.cornerRadiusFraction, 0)
    }

    func testEnsureCollapsedFABRestoresTheButtonAfterCloseWithoutExpanding() {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        state.close()
        XCTAssertNil(state.selection)
        state.ensureCollapsedFAB(target, machineId: "host", chatId: "chat")
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertEqual(state.selection?.machineId, "host")
        XCTAssertEqual(state.selection?.chatId, "chat")
        XCTAssertTrue(state.collapsed)
        XCTAssertEqual(state.targets, [target])
    }

    /// The host's own button (the iPhone Duo's strip) learns what the chat on
    /// screen has, and opens and minimises the panel as the round button did.
    func testTheHostsButtonFollowsAndTogglesThePanel() {
        let state = SimulatorPreviewState()
        XCTAssertEqual(SimulatorPreviewState.presence(state.selection, collapsed: state.collapsed, dockedUdid: nil), .none)
        state.open(target, machineId: "host", chatId: "chat")
        XCTAssertEqual(SimulatorPreviewState.presence(state.selection, collapsed: state.collapsed, dockedUdid: nil), .open)
        state.live = true
        state.toggleFromHostButton()
        XCTAssertTrue(state.collapsed)
        XCTAssertFalse(state.live, "minimised, the live video stops, as the panel's own minimise stops it")
        XCTAssertEqual(SimulatorPreviewState.presence(state.selection, collapsed: state.collapsed, dockedUdid: nil), .minimised)
        state.toggleFromHostButton()
        XCTAssertFalse(state.collapsed)
        // The dock showing it leaves the strip nothing to hold, and the button nothing to do.
        XCTAssertEqual(SimulatorPreviewState.presence(state.selection, collapsed: false, dockedUdid: target.udid.lowercased()), .none)
        state.close()
        state.toggleFromHostButton()
        XCTAssertFalse(state.collapsed)
        XCTAssertNil(state.selection)
    }

    func testABridgePublishesThePresenceOnTheNextTurn() async {
        let bridge = AgentBridge()
        XCTAssertEqual(bridge.simulatorPreviewPresence, .none)
        bridge.simulatorPreview.open(target, machineId: "host", chatId: "chat")
        // Not inside the change: a chat switch publishes during SwiftUI's update.
        XCTAssertEqual(bridge.simulatorPreviewPresence, .none)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.simulatorPreviewPresence, .open)
        bridge.toggleSimulatorPreview()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.simulatorPreviewPresence, .minimised)
        // Two of the host's places: the panel's own button comes back only
        // when neither holds it.
        bridge.setSimulatorPreviewButtonHost("strip", holds: true)
        bridge.setSimulatorPreviewButtonHost("bottomBar", holds: true)
        bridge.setSimulatorPreviewButtonHost("strip", holds: false)
        XCTAssertTrue(bridge.simulatorPreviewButtonHosted)
        bridge.setSimulatorPreviewButtonHost("bottomBar", holds: false)
        XCTAssertFalse(bridge.simulatorPreviewButtonHosted)
    }

    @available(iOS 26.0, *)
    func testASimulatorFloatedFromTheSimulatorsScreenBelongsToNoChat() {
        let bridge = AgentBridge()
        let floated = bridge.floatedSimulatorPreview
        let second = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        let elsewhere = SimulatorTarget(udid: "6A2D4C3B-1E0F-4A5B-8C7D-9E0F1A2B3C4D")
        bridge.floatSimulator(udid: target.udid, machineId: "studio")
        XCTAssertEqual(floated.selection, .init(target: target, machineId: "studio", chatId: SimulatorPreviewState.floatedChatId))
        XCTAssertFalse(floated.collapsed)
        XCTAssertTrue(floated.closeDismisses)
        XCTAssertNil(bridge.simulatorPreview.selection, "no chat's panel opens")
        XCTAssertFalse(bridge.simulatorPreview.closeDismisses)
        // A chat switch moves the chats' panel, not the floated one.
        bridge.simulatorPreview.show(chatId: "another chat")
        XCTAssertEqual(floated.selection?.target, target)
        // Another of the same Mac's joins its switch; another Mac's takes its place.
        bridge.floatSimulator(udid: second.udid, machineId: "studio")
        XCTAssertEqual(floated.targets, [target, second])
        XCTAssertEqual(floated.selection?.target, second)
        bridge.floatSimulator(udid: elsewhere.udid, machineId: "macbook")
        XCTAssertEqual(floated.targets, [elsewhere])
        XCTAssertEqual(floated.selection?.machineId, "macbook")
        // Minimised, floating it again brings it back.
        floated.collapsed = true
        bridge.floatSimulator(udid: elsewhere.udid, machineId: "macbook")
        XCTAssertFalse(floated.collapsed)
        // The live stream's shape goes to the panel showing that simulator only.
        bridge.simulatorPreview.open(target, machineId: "studio", chatId: "another chat")
        bridge.updateSimulatorPreviewGeometry(udid: elsewhere.udid, pointSize: CGSize(width: 466, height: 678), chrome: nil)
        XCTAssertEqual(floated.logicalScreenSize, CGSize(width: 466, height: 678))
        XCTAssertEqual(bridge.simulatorPreview.logicalScreenSize, .zero)
        XCTAssertEqual(bridge.simulatorPreviewInitialGeometry(udid: elsewhere.udid).screenSize, CGSize(width: 466, height: 678))
        // Its Close takes the simulator away: there is no chat for it to wait in.
        floated.close()
        XCTAssertNil(floated.selection)
        XCTAssertEqual(bridge.simulatorPreview.selection?.target, target)
        // A UDID that is not one opens nothing.
        bridge.floatSimulator(udid: "booted", machineId: "studio")
        XCTAssertNil(floated.selection)
    }

    func testChromeFollowsSnapshotAndComputesChassisAspectRatio() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        var snapshot = frame()
        let chromeDict: [String: Any] = [
            "topLeftRadius": 62.0,
            "topRightRadius": 62.0,
            "bottomRightRadius": 62.0,
            "bottomLeftRadius": 62.0,
            "bezelTop": 14.0,
            "bezelRight": 14.0,
            "bezelBottom": 14.0,
            "bezelLeft": 26.0,
            "hingeEdge": "left",
            "cutoutKind": "cornerHole",
            "cutoutEdge": "topRight",
            "quarterTurnsCCW": 0,
        ]
        snapshot["result"] = (snapshot["result"] as! [String: Any]).merging([
            "width": 384,
            "height": 830,
            "chrome": chromeDict,
        ]) { $1 }
        await state.refresh { _, _, _, _ in snapshot }
        XCTAssertEqual(state.chrome?.hingeEdge, "left")
        XCTAssertEqual(state.chrome?.cutoutKind, "cornerHole")
        XCTAssertEqual(state.logicalScreenSize, CGSize(width: 384, height: 830))
        // Total chassis width = 384 + (26+4) + (14+4) = 432, height = 830 + (14+26) + (14+26) = 910
        XCTAssertEqual(state.chassisAspectRatio, 432.0 / 910.0, accuracy: 0.001)
        // The empty band above the frame, which the panel tucks under its toolbar: 26 of the 910.
        XCTAssertEqual(state.chassisTopBand, 26.0 / 910.0, accuracy: 0.0001)
        state.close()
        XCTAssertNil(state.chrome)
        XCTAssertEqual(state.logicalScreenSize, .zero)
    }

    @available(iOS 26.0, *)
    func testTheToolbarKeepsWhatFitsAndLeavesTheRestToTheMenu() {
        typealias Panel = SimulatorPreviewPanel
        let all = Panel.Tool.allCases
        XCTAssertEqual(Panel.tools(all, width: 300), all)
        XCTAssertEqual(Panel.buttonWidth(count: all.count, width: 300), 42)
        // A third of a 440-point phone: the window button waits in the menu,
        // and Close goes too, as Minimise does the same.
        XCTAssertEqual(Panel.tools([.close, .menu, .window, .control, .minimise], width: 146.7),
                       [.menu, .control, .minimise])
        XCTAssertEqual(Panel.buttonWidth(count: 3, width: 146.7), 42)
        // Under Control a third of a 402-point phone leaves Home to the menu
        // as well, and the three left share the bar.
        XCTAssertEqual(Panel.tools(all, width: 134), [.menu, .control, .minimise])
        XCTAssertEqual(Panel.buttonWidth(count: 3, width: 134), 122.0 / 3, accuracy: 0.001)
        // The narrowest panel.
        XCTAssertEqual(Panel.tools(all, width: 120), [.menu, .control, .minimise])
        XCTAssertEqual(Panel.buttonWidth(count: 3, width: 120), 36)
    }

    func testSetLiveShowsToastDescribingModeChange() {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        XCTAssertFalse(state.live)
        XCTAssertNil(state.notice)

        state.setLive(true)
        XCTAssertTrue(state.live)
        XCTAssertEqual(state.notice, "Control mode — touch to interact, drag the toolbar to move")

        state.setLive(false)
        XCTAssertFalse(state.live)
        XCTAssertEqual(state.notice, "View mode — preview only")
    }

    func testOverlayLayoutSizesButtonsUniformlyAndStraddlesChromeBorder() {
        let screenSize = CGSize(width: 393, height: 852)
        let chrome = SimulatorDisplayChrome.defaultPhone
        let outsets = SimulatorChromePath.totalOutsets(for: chrome, includesButtonPadding: true)
        let ratio = (screenSize.width + outsets.left + outsets.right) / (screenSize.height + outsets.top + outsets.bottom)
        let containerSize = CGSize(width: 260, height: 260 / ratio)

        let layout = SimulatorChromePath.overlayLayout(
            in: containerSize,
            screenSize: screenSize,
            chrome: chrome
        )
        XCTAssertEqual(layout.buttonDiameter, 34)
        XCTAssertEqual(layout.iconFontSize, 13)

        let screenRect = SimulatorChromePath.screenRect(
            in: containerSize,
            screenSize: screenSize,
            chrome: chrome,
            includesButtonPadding: true
        )
        let scale = screenRect.width / screenSize.width
        let topBorderY = screenRect.minY - CGFloat(chrome.bezelTop) * scale + 1.5 * scale
        let topButtonCenterY = layout.topInset + layout.buttonDiameter * 0.5
        XCTAssertEqual(topButtonCenterY, topBorderY, accuracy: 1.5)

        let bottomBorderY = screenRect.maxY + CGFloat(chrome.bezelBottom) * scale - 1.5 * scale
        let bottomButtonCenterY = containerSize.height - layout.bottomInset - layout.buttonDiameter * 0.5
        XCTAssertEqual(bottomButtonCenterY, bottomBorderY, accuracy: 1.5)
    }

    func testMaximizingPausesStillsIgnoresAutomaticOpensAndRestoresCleanly() async {
        let state = SimulatorPreviewState()
        let other = SimulatorTarget(udid: "5F0C2B1E-7D3A-4C69-9E21-6A8B0D4E3F17")
        state.open(target, machineId: "host", chatId: "chat")
        // Without liveContent or fullScreenContent, maximize() does nothing.
        state.maximize()
        XCTAssertFalse(state.maximized)

        state.fullScreenContent = { _, _ in AnyView(EmptyView()) }
        state.collapsed = true
        state.maximize()
        XCTAssertTrue(state.maximized)
        XCTAssertFalse(state.collapsed)

        // Stills pause while maximized.
        await state.refresh { _, _, _, _ in XCTFail("No stills while maximized"); return [:] }

        // Automatic opens do not replace the maximized simulator.
        state.open(other, machineId: "host", chatId: "chat", automatic: true)
        XCTAssertEqual(state.selection?.target, target)
        XCTAssertTrue(state.maximized)

        // Folding while maximized refreshes fullScreenGeneration after foldSettles.
        state.invoke = { _, _, _, _ in ["success": true] }
        state.foldSettles = .milliseconds(1)
        let beforeFold = state.fullScreenGeneration
        await state.control("open")
        XCTAssertNotEqual(state.fullScreenGeneration, beforeFold)
        XCTAssertTrue(state.maximized)

        // Restoring leaves maximized false and fetches a fresh still.
        state.restoreFromMaximize()
        XCTAssertFalse(state.maximized)
        var refreshed = false
        await state.refresh { _, _, _, _ in refreshed = true; return self.frame() }
        XCTAssertTrue(refreshed)
    }
}
#endif
