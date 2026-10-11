import SwiftUI

/// The items of a Menu or a context menu.
///
/// macOS 27 draws a menu item's icon only when the item asks for it; macOS 26
/// drew it either way, and the iPhone always does. So on the Mac every menu's
/// items ask, by holding them in this.
///
/// It has to sit inside each menu. Asked for on the app's root, or on the
/// Menu itself, it does not reach the items: a menu takes its items' label
/// style from inside.
public struct MenuIcons<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if targetEnvironment(macCatalyst)
        content.labelStyle(.titleAndIcon)
        #else
        content
        #endif
    }
}
