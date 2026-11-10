#if os(iOS)
import SwiftUI
import XCTest
@testable import RipulAgent

@MainActor
final class MetadataColumnResizeTests: XCTestCase {
    private final class Counts {
        var bodies = 0
        var widthReports = 0
    }

    private struct Editor: UIViewRepresentable {
        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.accessibilityIdentifier = "metadata-resize-draft"
            view.text = "Keep this unsent draft"
            view.selectedRange = NSRange(location: 5, length: 4)
            return view
        }
        func updateUIView(_ uiView: UITextView, context: Context) {}
    }

    private struct Fixture: View {
        let counts: Counts
        @State private var reportedWidth: CGFloat = 0

        var body: some View {
            counts.bodies += 1
            return Editor()
                .modifier(DockedMetadataPane(panel: Color.gray, isPresented: true))
                // Reproduce the real screen's width-preference feedback path.
                .onPreferenceChange(RipulMetadataColumnWidthKey.self) {
                    counts.widthReports += 1
                    reportedWidth = $0
                }
                .accessibilityValue("\(reportedWidth)")
        }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func testDragDoesNotReflowChatOrPublishWidthsUntilRelease() async throws {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            throw XCTSkip("Run in the ThermalChecks hosted test target")
        }
        let counts = Counts()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(counts: counts))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 1400, height: 800)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(find(UITextView.self, in: host.view))
        let divider = try XCTUnwrap(find(MetadataColumnResizeView.self, in: host.view))
        divider.tintColor = .magenta
        let initialWidth = editor.bounds.width
        let bodies = counts.bodies
        let reports = counts.widthReports
        XCTAssertEqual(divider.bounds.width, 12, accuracy: 0.1)
        XCTAssertGreaterThan(divider.bounds.height, 600)

        divider.handleDrag(state: .began, translation: 0)
        for step in 1...100 {
            divider.handleDrag(state: .changed, translation: -CGFloat(step))
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
            XCTAssertEqual(editor.bounds.width, initialWidth)
            XCTAssertEqual(counts.widthReports, reports)
            XCTAssertEqual(counts.bodies, bodies)
            XCTAssertEqual(divider.previewWidth, 340 + CGFloat(step))
            let guide = try XCTUnwrap(divider.subviews.first)
            XCTAssertFalse(guide.isHidden)
            XCTAssertEqual(guide.center.x, divider.bounds.midX - CGFloat(step), accuracy: 0.1)
        }

        // The native guide must remain visible outside the 12pt grab area.
        // Read one pixel as a number; no screenshot or image attachment.
        let guide = try XCTUnwrap(divider.subviews.first)
        let point = guide.convert(CGPoint(x: 1, y: 200), to: host.view)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -point.x, y: -point.y)
            host.view.layer.render(in: context)
        }
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertLessThan(pixel[1], 15, "The resize guide must not be clipped or covered by the chat")
        XCTAssertGreaterThan(pixel[2], 240)

        // Use the release position, even if it differs from the last move.
        divider.handleDrag(state: .ended, translation: -120)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(divider.previewWidth)
        XCTAssertEqual(counts.widthReports, reports + 1)
        XCTAssertEqual(editor.bounds.width, initialWidth - 120, accuracy: 0.1)
        XCTAssertTrue(find(UITextView.self, in: host.view) === editor)
        XCTAssertEqual(editor.text, "Keep this unsent draft")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 5, length: 4))

        divider.handleDrag(state: .began, translation: 80)
        divider.handleDrag(state: .cancelled, translation: 80)
        divider.handleDrag(state: .ended, translation: 80)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counts.widthReports, reports + 1)
        XCTAssertEqual(editor.bounds.width, initialWidth - 120, accuracy: 0.1)
        XCTAssertNil(divider.previewWidth)
    }

    func testLimitsReversalCancellationAndAccessibility() {
        let divider = MetadataColumnResizeView()
        var committed: [CGFloat] = []
        divider.configure(width: 340, maximumWidth: 480) { committed.append($0) }
        divider.handleDrag(state: .began, translation: 0)
        divider.handleDrag(state: .changed, translation: -1000)
        XCTAssertEqual(divider.previewWidth, 480)
        divider.handleDrag(state: .changed, translation: 1000)
        XCTAssertEqual(divider.previewWidth, 280)
        divider.handleDrag(state: .changed, translation: -27)
        XCTAssertEqual(divider.previewWidth, 367, "Returning from a limit must follow the pointer precisely")
        XCTAssertTrue(committed.isEmpty)
        divider.handleDrag(state: .ended, translation: -27)
        XCTAssertEqual(committed, [367])

        divider.configure(width: 367, maximumWidth: 480) { committed.append($0) }
        divider.handleDrag(state: .began, translation: -20)
        // A streamed chat redraw must retain the in-flight guide.
        divider.configure(width: 367, maximumWidth: 480) { committed.append($0) }
        XCTAssertEqual(divider.previewWidth, 387)
        divider.handleDrag(state: .failed, translation: -20)
        XCTAssertNil(divider.previewWidth)
        XCTAssertEqual(committed, [367])

        divider.handleDrag(state: .began, translation: -20)
        divider.configure(width: 310, maximumWidth: 310) { committed.append($0) }
        divider.handleDrag(state: .ended, translation: -20)
        XCTAssertNil(divider.previewWidth, "Window geometry changes must cancel the old drag")
        XCTAssertEqual(committed, [367])
        divider.accessibilityIncrement()
        XCTAssertEqual(committed, [367], "No redundant commit at the upper limit")
        divider.accessibilityDecrement()
        XCTAssertEqual(committed, [367, 280])
        XCTAssertEqual(divider.accessibilityValue, "310 points")

        divider.configure(width: 340, maximumWidth: 480) { committed.append($0) }
        divider.handleDrag(state: .began, translation: -20)
        divider.accessibilityIncrement()
        XCTAssertNil(divider.previewWidth)
        XCTAssertEqual(committed.last, 380)
        divider.handleDrag(state: .ended, translation: -20)
        XCTAssertEqual(committed, [367, 280, 380])
    }

    func testActualDragFromGrabAreaCommitsOnce() async throws {
        if let reason = TouchSynthesizer.unavailableReason { throw XCTSkip(reason) }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            throw XCTSkip("Run in the ThermalChecks hosted test target")
        }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let counts = Counts()
        // Put a wide layout's divider on screen even on a narrow test phone.
        let host = UIHostingController(rootView: GeometryReader { _ in
            Fixture(counts: counts).frame(width: 1100, height: 600).offset(x: -600)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(250))
        let divider = try XCTUnwrap(find(MetadataColumnResizeView.self, in: host.view))
        let editor = try XCTUnwrap(find(UITextView.self, in: host.view))
        // Start 4pt off the visible separator: the wider grab area must work.
        let start = divider.convert(CGPoint(x: divider.bounds.midX + 4, y: 200), to: window)
        XCTAssertTrue(window.bounds.contains(start))
        XCTAssertTrue(window.hitTest(start, with: nil) === divider)
        let reports = counts.widthReports
        let originalWidth = editor.bounds.width
        try await TouchSynthesizer.drag(from: start, to: CGPoint(x: start.x - 80, y: start.y),
                                        in: window, duration: 0.6)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counts.widthReports, reports + 1)
        XCTAssertEqual(editor.bounds.width, originalWidth - 80, accuracy: 1)
        XCTAssertNil(divider.previewWidth)
    }
}
#endif
