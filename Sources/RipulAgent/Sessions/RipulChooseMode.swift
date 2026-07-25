import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Choose-mode state for the `ripul://choose` hand-off: another app asks Ripul
/// (or an SDK host) for a session to work in; picking a row returns the session
/// to the caller via its callback URL instead of opening it.
///
/// Ported verbatim from the native app (`iOS/ContentView.swift`) for the M8
/// whole-screen extraction. The screen treats it as an optional slot — hosts
/// without a choose hand-off pass nil and no banner/interception appears.
@available(iOS 15.0, macOS 13.0, *)
public final class RipulChooseMode: ObservableObject {
    @Published public private(set) var active = false
    public private(set) var appName: String?
    private var callback: URL?

    public init() {}

    public func begin(callback: URL, appName: String?) {
        self.callback = callback
        self.appName = appName
        active = true
    }

    public func cancel() { active = false; callback = nil; appName = nil }

    /// Return the picked session to the caller, then exit choose mode.
    public func pick(_ session: ChatSession) {
        guard active, let cb = callback,
              var comps = URLComponents(url: cb, resolvingAgainstBaseURL: false) else { cancel(); return }
        comps.queryItems = [URLQueryItem(name: "id", value: session.id),
                            URLQueryItem(name: "title", value: session.displayName)]
        let out = comps.url
        cancel()
        if let out {
            #if os(iOS)
            UIApplication.shared.open(out)
            #elseif os(macOS)
            NSWorkspace.shared.open(out)
            #endif
        }
    }
}
