#if os(iOS)
import UIKit

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

@MainActor
enum NativeTextRuntime {
    private(set) static var current = NativeTextTheme()

    static func adopt(_ theme: NativeTextTheme) {
        current = theme
        NativeTabTitleTheme.clearPreviews()
        NativeLabelTheme.clearPreviews()
        NativeTabTitleTheme.reapply()
        NativeLabelTheme.refresh(discover: !theme.labels.isEmpty)
    }

    static func mutate(_ edit: (inout NativeTextTheme) -> Void) {
        let before = Set(current.labels.map(\.id))
        edit(&current)
        NativeTabTitleTheme.reapply()
        NativeLabelTheme.refresh(discover: before != Set(current.labels.map(\.id)))
        NotificationCenter.default.post(name: .ripulThemeDidChange, object: nil)
    }
}
#endif
