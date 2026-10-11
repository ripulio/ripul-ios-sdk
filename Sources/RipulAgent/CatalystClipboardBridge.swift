#if targetEnvironment(macCatalyst)
import UIKit
import WebKit

/// Copies from the web chat reach the Mac clipboard through the app, not
/// through WebKit.
///
/// In a Catalyst WKWebView, `navigator.clipboard.writeText` fails in two ways
/// (measured in the running app, 8 October 2026). A real mouse click arrives
/// trusted but without user activation, so WebKit rejects the write with
/// `NotAllowedError`. And a write WebKit does accept puts only its own
/// `com.apple.WebKit.custom-pasteboard-data` on the pasteboard, with no plain
/// text, so nothing pastes. Every copy button in the web app calls
/// `writeText`, so replacing that one function fixes all of them.
@available(iOS 15.0, *)
@MainActor
final class CatalystClipboardBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "agentClipboard"

    /// Longest text accepted, in UTF-8 bytes.
    private static let maxBytes = 8 * 1024 * 1024

    private let baseHost: String?
    private let standalone: Bool

    init(baseHost: String?, standalone: Bool) {
        self.baseHost = baseHost
        self.standalone = standalone
    }

    /// Replaces `navigator.clipboard.writeText` with a call to this handler.
    /// A refusal rejects the promise, so a caller's own fallback still runs.
    static let userScript = WKUserScript(
        source: """
        (function() {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            if (!handler) return;
            var writeText = function(text) {
                return handler.postMessage(String(text == null ? '' : text)).then(function() {});
            };
            var clipboard = navigator.clipboard;
            try {
                if (clipboard) {
                    Object.defineProperty(clipboard, 'writeText', { configurable: true, writable: true, value: writeText });
                } else {
                    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: writeText } });
                }
            } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    func install(in controller: WKUserContentController) {
        controller.addUserScript(Self.userScript)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        // Frames can address WebKit handlers without our injected script, so
        // only the app's own page may write the clipboard.
        guard trusts(message) else { return replyHandler(nil, "Clipboard is not available to this frame") }
        guard let text = message.body as? String, text.utf8.count <= Self.maxBytes else {
            return replyHandler(nil, "Clipboard text is missing or too long")
        }
        UIPasteboard.general.string = text
        replyHandler(true, nil)
    }

    private func trusts(_ message: WKScriptMessage) -> Bool {
        if standalone { return BundledAgentRuntime.shared.trusts(message) }
        let origin = message.frameInfo.securityOrigin
        return message.frameInfo.isMainFrame && origin.protocol == "https" && origin.host == baseHost
            && (origin.port == 0 || origin.port == 443)
    }
}
#endif
