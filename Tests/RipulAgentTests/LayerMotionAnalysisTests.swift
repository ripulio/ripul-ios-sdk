import XCTest
@testable import RipulAgent

final class LayerMotionAnalysisTests: XCTestCase {
    func testSmoothMonotonicTransitionHasNoAnomalies() {
        // 300ms slide from x=0 to x=300 at 60fps (~16ms steps), then stationary.
        var samples: [LayerMotionAnalysis.Sample] = []
        for step in 0...25 {
            let ms = step * 16
            let progress = min(1.0, Double(ms) / 300.0)
            let x = 300.0 * progress
            samples.append(LayerMotionAnalysis.Sample(ms: ms, x: x, y: 100, w: 390, h: 844))
        }
        let summary = LayerMotionAnalysis.summarize(samples: samples, maxKeyframes: 10)
        XCTAssertNotNil(summary)
        guard let summary else { return }
        XCTAssertEqual(summary.firstMovedMs, 16)
        XCTAssertEqual(summary.settledAtMs, 304)
        XCTAssertEqual(summary.activeDurationMs, 288)
        XCTAssertEqual(summary.kinds, ["position"])
        XCTAssertTrue(summary.anomalies.isEmpty, "Expected no anomalies on smooth slide, got \(summary.anomalies)")
        XCTAssertLessThanOrEqual(summary.keyframes.count, 10)
        XCTAssertEqual(summary.keyframes.first?.ms, 0)
        XCTAssertEqual(summary.keyframes.last?.ms, 304)
    }

    func testDetectsSingleFrameFlashSpike() {
        // Stationary at opacity=0, then a 1-frame full-screen flash at +48ms (opacity=1, w=390, h=844),
        // snapping back to opacity=0 at +64ms, before smoothly expanding from +80ms to +320ms.
        var samples: [LayerMotionAnalysis.Sample] = [
            LayerMotionAnalysis.Sample(ms: 0, x: 300, y: 700, w: 56, h: 56, opacity: 0.0),
            LayerMotionAnalysis.Sample(ms: 16, x: 300, y: 700, w: 56, h: 56, opacity: 0.0),
            LayerMotionAnalysis.Sample(ms: 32, x: 300, y: 700, w: 56, h: 56, opacity: 0.0),
            // 1-frame flash!
            LayerMotionAnalysis.Sample(ms: 48, x: 0, y: 0, w: 390, h: 844, opacity: 1.0),
            // Snaps back on the very next frame:
            LayerMotionAnalysis.Sample(ms: 64, x: 300, y: 700, w: 56, h: 56, opacity: 0.0),
        ]
        for step in 5...20 {
            let ms = step * 16
            let t = Double(step - 4) / 16.0
            samples.append(LayerMotionAnalysis.Sample(
                ms: ms,
                x: 300.0 * (1.0 - t),
                y: 700.0 * (1.0 - t),
                w: 56.0 + (390.0 - 56.0) * t,
                h: 56.0 + (844.0 - 56.0) * t,
                opacity: t
            ))
        }

        let summary = LayerMotionAnalysis.summarize(samples: samples)
        XCTAssertNotNil(summary)
        guard let summary else { return }
        let spike = summary.anomalies.first { $0.kind == "single_frame_spike" }
        XCTAssertNotNil(spike, "Expected single_frame_spike anomaly, got \(summary.anomalies)")
        XCTAssertEqual(spike?.atMs, 48)
        XCTAssertTrue(summary.keyframes.contains { $0.ms == 48 }, "Keyframes must preserve the spike frame")
    }

    func testDetectsMidFlightFreeze() {
        // Chrome bar collapses halfway (y=580 -> y=602 over 0..64ms), freezes for 400ms (64..464ms),
        // then finishes collapsing to y=624 (464..560ms).
        var samples: [LayerMotionAnalysis.Sample] = [
            LayerMotionAnalysis.Sample(ms: 0, x: 0, y: 580, w: 390, h: 48),
            LayerMotionAnalysis.Sample(ms: 16, x: 0, y: 586, w: 390, h: 48),
            LayerMotionAnalysis.Sample(ms: 32, x: 0, y: 592, w: 390, h: 48),
            LayerMotionAnalysis.Sample(ms: 48, x: 0, y: 597, w: 390, h: 48),
            LayerMotionAnalysis.Sample(ms: 64, x: 0, y: 602, w: 390, h: 48),
        ]
        // Frozen at y=602 from 80ms through 464ms:
        for ms in stride(from: 80, through: 464, by: 16) {
            samples.append(LayerMotionAnalysis.Sample(ms: ms, x: 0, y: 602, w: 390, h: 48))
        }
        // Resumes settling at 480ms:
        samples.append(LayerMotionAnalysis.Sample(ms: 480, x: 0, y: 610, w: 390, h: 48))
        samples.append(LayerMotionAnalysis.Sample(ms: 496, x: 0, y: 618, w: 390, h: 48))
        samples.append(LayerMotionAnalysis.Sample(ms: 512, x: 0, y: 624, w: 390, h: 48))

        let summary = LayerMotionAnalysis.summarize(samples: samples)
        XCTAssertNotNil(summary)
        guard let summary else { return }
        let freeze = summary.anomalies.first { $0.kind == "mid_flight_freeze" }
        XCTAssertNotNil(freeze, "Expected mid_flight_freeze anomaly, got \(summary.anomalies)")
        XCTAssertEqual(freeze?.atMs, 64)
        XCTAssertEqual(freeze?.durationMs, 416)
    }

    func testDetectsDirectionReversalNod() {
        // Entry "nod": view starts at y=100, dips down to y=118 at +80ms, then rises back to y=100 at +176ms.
        let samples: [LayerMotionAnalysis.Sample] = [
            LayerMotionAnalysis.Sample(ms: 0, x: 0, y: 100, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 16, x: 0, y: 104, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 32, x: 0, y: 109, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 48, x: 0, y: 114, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 64, x: 0, y: 118, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 80, x: 0, y: 113, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 96, x: 0, y: 107, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 112, x: 0, y: 102, w: 390, h: 700),
            LayerMotionAnalysis.Sample(ms: 128, x: 0, y: 100, w: 390, h: 700),
        ]
        let summary = LayerMotionAnalysis.summarize(samples: samples)
        XCTAssertNotNil(summary)
        guard let summary else { return }
        let reversal = summary.anomalies.first { $0.kind == "reversal" && $0.property == "y" }
        XCTAssertNotNil(reversal, "Expected y reversal anomaly, got \(summary.anomalies)")
        XCTAssertEqual(reversal?.atMs, 64)
    }
}
