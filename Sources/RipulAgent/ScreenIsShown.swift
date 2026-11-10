import SwiftUI

private struct ScreenIsShownKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the screen a view is on is not on screen: a tab behind
    /// another (the app's `HiddenTabHold` sets it). A view that follows
    /// frequent changes, such as the session list's recency, stops following
    /// them while this is false and catches up when it turns true: hidden
    /// screens do no work (docs/main-thread.md, rule 5).
    public var screenIsShown: Bool {
        get { self[ScreenIsShownKey.self] }
        set { self[ScreenIsShownKey.self] = newValue }
    }
}
