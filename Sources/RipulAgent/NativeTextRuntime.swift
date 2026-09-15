#if os(iOS)
import UIKit
import Combine

enum NativeTextHooks {
    static func intercept(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let old = class_getInstanceMethod(type, original), let new = class_getInstanceMethod(type, replacement) else {
            assertionFailure("[RipulTheme] Missing public text selector"); return
        }
        if class_addMethod(type, original, method_getImplementation(new), method_getTypeEncoding(new)) {
            class_replaceMethod(type, replacement, method_getImplementation(old), method_getTypeEncoding(old))
        } else { method_exchangeImplementations(old, new) }
    }
}

/// Shared invalidation for SwiftUI text, including views hosted inside List rows
/// or sheets that may not inherit a host screen's theme-version environment.
@MainActor
final class NativeTextUpdates: ObservableObject {
    @Published private(set) var version = 0
    func invalidate() { version &+= 1 }
}

@MainActor
enum NativeTextRuntime {
    static let updates = NativeTextUpdates()
    private(set) static var current = NativeTextTheme()

    static func adopt(_ theme: NativeTextTheme) {
        current = theme
        updates.invalidate()
        NativeTabTitleTheme.clearPreviews()
        NativeLabelTheme.clearPreviews()
        NativeTabTitleTheme.reapply()
        NativeLabelTheme.refresh(discover: !theme.labels.isEmpty)
    }

    static func mutate(_ edit: (inout NativeTextTheme) -> Void) {
        let before = Set(current.labels.map(\.id))
        edit(&current)
        updates.invalidate()
        NativeTabTitleTheme.reapply()
        NativeLabelTheme.refresh(discover: before != Set(current.labels.map(\.id)))
        NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
    }
}
#endif
