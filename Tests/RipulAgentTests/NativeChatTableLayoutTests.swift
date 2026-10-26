#if os(macOS)
import AppKit
import MarkdownUI
import SwiftUI
import XCTest
@testable import RipulAgent

final class NativeChatTableLayoutTests: XCTestCase {
    @MainActor
    func testDescriptionTableFitsPhoneAndExpandsWhenResized() {
        let model = TableModel(source: """
        | Description | Count |
        | :--- | ---: |
        | A longer explanation should wrap into readable lines while keeping the numeric column compact. | 42 |
        | Done | 123 |
        """, width: 280)
        withHost(model) { host, recorder in
            select(.fit, in: host)
            let narrow = recorder.cells["1:0"]!
            let number = recorder.cells["1:1"]!
            XCTAssertGreaterThan(narrow.width, number.width * 2)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 280.5)
            XCTAssertEqual(narrow.minY, number.minY, accuracy: 0.5)
            XCTAssertEqual(narrow.height, number.height, accuracy: 0.5)
            model.width = 600
            pump(host)
            XCTAssertGreaterThan(recorder.cells["1:0"]!.width, narrow.width)
            XCTAssertLessThan(recorder.cells["1:0"]!.height, narrow.height)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 600.5)
        }
    }

    @MainActor
    func testLongPathWrapsWithoutMakingItsColumnEnormous() {
        let model = TableModel(source: """
        | File | Status |
        | --- | --- |
        | `ripul-ios-sdk/Sources/RipulAgent/ToolRenderers/NativeToolComponents.swift` | **Ready** |
        | Short | Done |
        """, width: 320)
        withHost(model) { host, recorder in
            select(.fit, in: host)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 320.5)
            XCTAssertGreaterThan(recorder.cells["1:0"]!.height, recorder.cells["2:0"]!.height)
        }
    }

    @MainActor
    func testWideTableKeepsReadableColumnsInsideMessage() {
        let model = TableModel(source: """
        | First heading | Second heading | Third heading | Fourth heading | Fifth heading |
        | --- | --- | --- | --- | --- |
        | A long first value | A long second value | A long third value | A long fourth value | A long fifth value |
        """, width: 320)
        withHost(model) { host, recorder in
            XCTAssertGreaterThan(tableWidth(recorder), 320)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 480.5)
            for column in 0..<5 {
                XCTAssertGreaterThanOrEqual(recorder.cells["1:\(column)"]!.width, 80)
            }
            let scrollers = descendants(host).compactMap { $0 as? NSScrollView }
            XCTAssertEqual(scrollers.count, 1)
            XCTAssertLessThanOrEqual(scrollers.first!.bounds.width, 320.5)
            XCTAssertGreaterThan(scrollers.first!.documentView!.bounds.width, 320)
        }
    }

    @MainActor
    func testLargerTextGrowsRowsWithoutClipping() {
        let model = TableModel(source: """
        | Description | Status |
        | --- | --- |
        | A longer explanation with several words that need room to wrap. | Ready |
        """, width: 320)
        withHost(model) { host, recorder in
            let regularHeight = recorder.cells["1:0"]!.height
            // macOS does not scale ScaledMetric for iOS Dynamic Type categories.
            // Exercise larger rendered text directly in this macOS hosted test.
            model.fontSize = 28
            pump(host)
            XCTAssertGreaterThan(recorder.cells["1:0"]!.height, regularHeight)
            XCTAssertEqual(recorder.cells["1:0"]!.height, recorder.cells["1:1"]!.height, accuracy: 0.5)
            XCTAssertGreaterThan(recorder.cells["1:0"]!.width, 96)
        }
    }

    @MainActor
    func testWidthControlOffersThreeDifferentLayoutsAndInvalidatesRowHeight() {
        let model = TableModel(source: widthFixture, width: 320)
        var invalidated: [String] = []
        model.registry.onRowStateChanged = { invalidated.append($0) }
        withHost(model) { host, recorder in
            let balancedWidth = tableWidth(recorder)
            let balancedHeight = recorder.cells["1:0"]!.height
            XCTAssertGreaterThan(balancedWidth, 320)
            XCTAssertLessThanOrEqual(balancedWidth, 480.5)

            select(.fit, in: host)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 320.5)
            XCTAssertGreaterThan(recorder.cells["1:0"]!.height, balancedHeight)

            select(.wide, in: host)
            XCTAssertGreaterThan(tableWidth(recorder), balancedWidth)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 800.5)
            XCTAssertLessThan(recorder.cells["1:0"]!.height, balancedHeight)
            XCTAssertEqual(invalidated, ["message", "message"])
            XCTAssertEqual(model.registry.value(forRow: "message", component: "table.width:0",
                                                default: NativeChatTableWidth.balanced), .wide)

            // Changing back to Fit after scrolling right must not strand the
            // reader in an empty portion of the old, wider scroll surface.
            let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first!
            scroll.contentView.scroll(to: NSPoint(x: 400, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(host)
            XCTAssertGreaterThan(scroll.documentVisibleRect.minX, 0)
            select(.fit, in: host)
            XCTAssertLessThanOrEqual(scroll.documentVisibleRect.minX, 0.5)
            XCTAssertLessThanOrEqual(tableWidth(recorder), 320.5)
        }
    }

    @MainActor
    func testIndependentTableChoicesSurviveStreamingAndRemount() {
        let quoted = widthFixture.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let model = TableModel(source: widthFixture + "\n\n" + quoted, width: 320)
        withHost(model) { host, recorder in
            select(.fit, in: host)
            select(.wide, in: host, index: 1)
            let firstWidth = tableWidth(recorder)
            let secondWidth = tableWidth(recorder, path: "1.0")
            XCTAssertGreaterThan(secondWidth, firstWidth)

            model.source += "\n> | A streamed row | More text | Another value | Final value |"
            pump(host)
            XCTAssertEqual(tableWidth(recorder), firstWidth, accuracy: 0.5)
            XCTAssertGreaterThan(tableWidth(recorder, path: "1.0"), firstWidth)

            model.visible = false
            pump(host)
            model.visible = true
            pump(host)
            XCTAssertEqual(tableWidth(recorder), firstWidth, accuracy: 0.5)
            XCTAssertEqual(tableWidth(recorder, path: "1.0"), secondWidth, accuracy: 0.5)
            XCTAssertEqual(widthItem(.fit, in: host)?.state, .on)
            XCTAssertEqual(widthItem(.wide, in: host, index: 1)?.state, .on)
        }
    }

    private var widthFixture: String {
        """
        | First column | Second column | Third column | Fourth column |
        | --- | --- | --- | --- |
        | A long description with plenty of words to show the difference between wrapping and scrolling. | Another detailed description with enough words to wrap onto several lines. | A third longer explanation which needs a sensible width for reading. | The final description also needs several lines when the table fits the chat. |
        """
    }

    private func tableWidth(_ recorder: TableRecorder, path: String = "0") -> CGFloat {
        (recorder.tables[path] ?? [:]).values.reduce(CGRect.null) { $0.union($1) }.width + 2
    }

    @MainActor
    private func widthMenu(in host: NSView, index: Int = 0) -> NSButton? {
        // SwiftUI exposes its accessibility identifier on a virtual element;
        // select the real native controls in this fixture's document order.
        let menus = descendants(host).compactMap { $0 as? NSButton }.filter { button in
            // Menu builds its items when opened, unlike a standalone Picker.
            // Open the real control, then dismiss tracking before selecting.
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated { button.menu?.cancelTracking() }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            timer.invalidate()
            guard let menu = button.menu else { return false }
            let titles = menuItems(menu).map(\.title)
            return NativeChatTableWidth.allCases.allSatisfy { titles.contains($0.title) }
        }
        return index < menus.count ? menus[index] : nil
    }

    @MainActor
    private func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
    }

    @MainActor
    private func widthItem(_ mode: NativeChatTableWidth, in host: NSView, index: Int = 0) -> NSMenuItem? {
        widthMenu(in: host, index: index)?.menu.flatMap { menu in
            menuItems(menu).first { $0.title == mode.title }
        }
    }

    @MainActor
    private func select(_ mode: NativeChatTableWidth, in host: NSView, index: Int = 0) {
        guard let item = widthItem(mode, in: host, index: index), let menu = item.menu else {
            XCTFail("Missing width option \(mode.title)")
            return
        }
        menu.performActionForItem(at: menu.index(of: item))
        pump(host)
    }

    @MainActor
    private func withHost(_ model: TableModel, check: (NSView, TableRecorder) -> Void) {
        let recorder = TableRecorder()
        let host = NSHostingView(rootView: TableFixture(model: model, recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        pump(host)
        check(host, recorder)
    }

    @MainActor
    private func pump(_ host: NSView) {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private final class TableModel: ObservableObject {
    @Published var source: String
    @Published var width: CGFloat
    @Published var fontSize: CGFloat = 14.5
    @Published var visible = true
    let registry = NativeChatRowStateRegistry()
    init(source: String, width: CGFloat) { self.source = source; self.width = width }
}

private final class TableRecorder {
    var tables: [String: [String: CGRect]] = [:]
    var cells: [String: CGRect] { tables["0"] ?? [:] }
}

private struct TableFixture: View {
    @ObservedObject var model: TableModel
    let recorder: TableRecorder

    var body: some View {
        Group {
            if model.visible { markdown }
        }
        .nativeChatRowStateRoot(registry: model.registry, rowId: "message")
        .frame(width: model.width)
        .coordinateSpace(name: "message")
        .onPreferenceChange(TableCellFrames.self) { recorder.tables = $0 }
    }

    private var markdown: some View {
        Markdown(NativeChatMarkdownDocument.parse(model.source))
            .markdownTheme(NativeChatMarkdownTheme.theme.text {
                FontSize(model.fontSize)
            }.tableCell { configuration in
                MeasuredTableCell(configuration: configuration)
            })
            .markdownSoftBreakMode(.lineBreak)
    }
}

private struct MeasuredTableCell: View {
    let configuration: TableCellConfiguration
    @Environment(\.markdownBlockPath) private var blockPath

    var body: some View {
        NativeChatMarkdownTableCell(configuration: configuration)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TableCellFrames.self, value: [
                        blockPath.map(String.init).joined(separator: "."): [
                            "\(configuration.row):\(configuration.column)": proxy.frame(in: .named("message"))
                        ]
                    ])
                }
            }
    }
}

private struct TableCellFrames: PreferenceKey {
    static let defaultValue: [String: [String: CGRect]] = [:]
    static func reduce(value: inout [String: [String: CGRect]], nextValue: () -> [String: [String: CGRect]]) {
        value.merge(nextValue(), uniquingKeysWith: { old, new in
            old.merging(new, uniquingKeysWith: { _, new in new })
        })
    }
}
#endif
