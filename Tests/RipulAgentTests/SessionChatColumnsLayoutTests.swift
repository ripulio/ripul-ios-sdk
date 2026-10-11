#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import RipulAgent

/// The session list and the chat share one ZStack (`SessionChatColumns`, which
/// is iOS only, so its shape is rebuilt here). A list whose content could not
/// fit stretched the chat with it; `keepsOfferedHeight` is what stops that.
@MainActor
final class SessionChatColumnsLayoutTests: XCTestCase {
    /// The chat's height in a 440 x 956 container, beside a list whose content
    /// is `listContent` tall.
    private func chatHeight(listContent: CGFloat, contained: Bool) -> CGFloat {
        var measured: CGFloat = 0
        // As GlassSessionsList is built: panels in a top-aligned frame that fills what it is given.
        let list = VStack { Color.blue.frame(height: listContent) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let columns = ZStack(alignment: .leading) {
            if contained { list.keepsOfferedHeight().frame(width: 440) } else { list.frame(width: 440) }
            // As a web view behaves: it takes whatever it is offered.
            Color.red
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
                .frame(width: 440)
        }
        let host = NSHostingView(rootView: columns)
        host.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return measured
    }

    func testAListTallerThanTheScreenStretchesTheChatBesideIt() {
        // The hazard itself. If this stops being true the guard is no longer needed.
        XCTAssertEqual(chatHeight(listContent: 2000, contained: false), 2000, accuracy: 1)
    }

    func testAContainedListLeavesTheChatAtTheScreensHeight() {
        XCTAssertEqual(chatHeight(listContent: 2000, contained: true), 956, accuracy: 1)
        XCTAssertEqual(chatHeight(listContent: 600, contained: true), 956, accuracy: 1)
    }
}
#endif
