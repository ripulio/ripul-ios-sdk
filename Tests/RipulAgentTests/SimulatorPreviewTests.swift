#if os(iOS)
import XCTest
import UIKit
import Combine
@testable import RipulAgent

@MainActor
final class SimulatorPreviewTests: XCTestCase {
    private let target = SimulatorTarget(udid: "08E561AA-A868-4196-AF4A-3501D80DF965")
    private func resolved(choices: Bool = false) -> [String: Any] {
        ["success": true, "result": ["needsChoice": choices, "windows": [["id": 42, "title": "iPhone", "frame": ["width": 494.0, "height": 1054.0]]]]]
    }
    private func frame() -> [String: Any] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }
        return ["success": true, "result": ["jpegB64": image.jpegData(compressionQuality: 0.5)!.base64EncodedString()]]
    }
    func testDuplicateFramesDoNotDecodeOrInvalidatePanel() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        let sameFrame = frame()
        let invoke: SimulatorPreviewState.Invoke = { _, method, _, _ in method == "simulatorWindows" ? self.resolved() : sameFrame }
        await state.refresh(invoke: invoke)
        let first = state.image
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
        let changed = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }.jpegData(compressionQuality: 0.5)!.base64EncodedString()
        await state.refresh { _, _, _, _ in ["success": true, "result": ["jpegB64": changed]] }
        XCTAssertEqual(frameUpdates, 1)
        XCTAssertEqual(panelUpdates, 0)
    }

    func testUsesOwningHostAndPausesWhileCollapsedOrHidden() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "original-host", chatId: "chat")
        var methods: [String] = []
        let invoke: SimulatorPreviewState.Invoke = { machine, method, args, chat in
            XCTAssertEqual(machine, "original-host")
            XCTAssertEqual(chat, "chat")
            methods.append(method)
            if method == "simulatorWindows" {
                XCTAssertEqual((args.first as? [String: Any])?["udid"] as? String, self.target.udid)
                return self.resolved()
            }
            XCTAssertEqual(args[0] as? Int, 42)
            return self.frame()
        }
        await state.refresh(invoke: invoke)
        XCTAssertNotNil(state.image)
        state.collapsed = true
        await state.refresh(invoke: invoke)
        XCTAssertEqual(methods, ["simulatorWindows", "snapshot"])
        state.collapsed = false; state.allowed = false
        await state.refresh(invoke: invoke)
        XCTAssertEqual(methods.count, 2)
        state.allowed = true
        await state.refresh(invoke: invoke)
        XCTAssertEqual(methods, ["simulatorWindows", "snapshot", "snapshot"])
    }
    func testAmbiguousDeviceNeverCapturesUntilChosen() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        var calls = 0
        await state.refresh { _, method, _, _ in calls += 1; XCTAssertEqual(method, "simulatorWindows"); return self.resolved(choices: true) }
        XCTAssertNil(state.image)
        await state.refresh { _, _, _, _ in XCTFail("Awaiting explicit choice"); return [:] }
        XCTAssertEqual(calls, 1)
        state.choose(state.windows[0])
        await state.refresh { _, method, _, _ in XCTAssertEqual(method, "snapshot"); return self.frame() }
        XCTAssertNotNil(state.image)
    }
    func testClosingOrReplacingTargetDiscardsDelayedFramesAndPreventsOverlap() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        var pending: CheckedContinuation<[String: Any], Never>?
        let task = Task {
            await state.refresh { _, method, _, _ in
                if method == "simulatorWindows" { return self.resolved() }
                return await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await state.refresh { _, _, _, _ in XCTFail("Overlapping capture"); return [:] }
        state.close()
        state.open(target, machineId: "different-host", chatId: "another-chat")
        pending?.resume(returning: frame())
        await task.value
        XCTAssertNil(state.image)
        XCTAssertNil(state.window)
        XCTAssertEqual(state.selection?.machineId, "different-host")
    }
    func testErrorsStopPollingUntilRetry() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        await state.refresh { _, _, _, _ in ["success": false, "error": "Host disconnected"] }
        XCTAssertEqual(state.error, "Host disconnected")
        await state.refresh { _, _, _, _ in XCTFail("Must wait for Retry"); return [:] }
        state.retry()
        await state.refresh { _, method, _, _ in method == "simulatorWindows" ? self.resolved() : self.frame() }
        XCTAssertNotNil(state.image)
        XCTAssertNil(state.error)
    }

    func testAppearanceFollowsAppliedCropAndCapturedAspectRatio() async {
        let state = SimulatorPreviewState()
        state.open(target, machineId: "host", chatId: "chat")
        await state.refresh { _, method, _, _ in
            if method == "simulatorWindows" {
                var response = self.resolved()
                var value = response["result"] as! [String: Any]
                value["appearance"] = ["cropPresetId": "device", "cornerRadiusFraction": 0.14]
                response["result"] = value
                return response
            }
            var response = self.frame()
            var value = response["result"] as! [String: Any]
            value["cropPresetId"] = "device"
            response["result"] = value
            return response
        }
        XCTAssertEqual(state.aspectRatio, 0.5, accuracy: 0.001) // Image is 32x64; desktop window is 494x1054.
        XCTAssertEqual(state.appearance?.cornerRadius(for: CGSize(width: 200, height: 400)) ?? -1, 28, accuracy: 0.001)
        XCTAssertEqual(state.appearance?.cornerRadius(for: CGSize(width: 400, height: 200)) ?? -1, 28, accuracy: 0.001)
        XCTAssertEqual(state.appearance?.cornerRadius(for: CGSize(width: 100, height: 200)) ?? -1, 14, accuracy: 0.001)
        await state.refresh { _, _, _, _ in self.frame() } // A full-window fallback has no applied preset.
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
}
#endif
