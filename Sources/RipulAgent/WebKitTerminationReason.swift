import Foundation

/// The category supplied by WebKit, not an inferred OS crash diagnosis.
/// In particular, "Crash" also covers several kinds of process termination;
/// it does not establish a JavaScript exception or exclude an OS memory kill.
public struct WebKitTerminationReason: Codable, Sendable {
    public let rawValue: Int
    public let label: String

    init(rawValue: Int) {
        self.rawValue = rawValue
        // WKNavigationDelegatePrivate.h, _WKProcessTerminationReason.
        // Keep unfamiliar values so a changed OS remains diagnosable.
        switch rawValue {
        case 0: label = "ExceededMemoryLimit"
        case 1: label = "ExceededCPULimit"
        case 2: label = "RequestedByClient"
        case 3: label = "Crash"
        case 4: label = "ExceededSharedProcessCrashLimit"
        default: label = "Unknown"
        }
    }
}

#if DEBUG || RIPUL_DEVELOPER_BUILD
import WebKit

extension AgentWebView.Coordinator {
    // Developer-only SPI: the public callback supplies no reason, and the
    // phone's OSLogStore can return no WebKit messages. WebKit discovers this
    // selector at runtime and calls it INSTEAD OF the public callback. Both
    // must enter the same recording/recovery path, exactly once. If an OS no
    // longer supports this selector, the public callback remains available.
    // Source: WebKit/UIProcess/Cocoa/NavigationState.mm, processDidTerminate.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, didTerminateWithReason reason: Int) {
        Task { @MainActor in
            bridge.recordProcessTermination(reason: WebKitTerminationReason(rawValue: reason))
        }
    }
}
#endif
