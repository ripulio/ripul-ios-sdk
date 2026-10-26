#if os(iOS)
import SwiftUI

public extension View {
    /// A Done button above the keyboard, declared only while `focused` is true.
    ///
    /// SwiftUI puts every `.keyboard` toolbar in the window into the one bar
    /// above whichever field has focus: toolbars in other hosting controllers,
    /// hidden ones (a question card scrolled away, a chat kept alive behind the
    /// one on screen) and an alert's text field included. Declared all the
    /// time, each adds its own Done, so on 23 October 2026 the rename alert had
    /// four. Pass the focus of the fields this button ends editing in;
    /// `check_keyboard_toolbars.py` refuses a `.keyboard` toolbar anywhere else.
    func keyboardDoneButton(when focused: Bool, action: @escaping () -> Void) -> some View {
        toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done", action: action)
                }
            }
        }
    }
}
#endif
