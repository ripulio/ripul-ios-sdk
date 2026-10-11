import SwiftUI

extension View {
    /// Reports exactly the height it is offered, however tall its content
    /// insists on being. The content keeps its own size, pinned to the top,
    /// and runs past the bottom.
    ///
    /// For a view that shares a ZStack with one that must not grow. A ZStack
    /// lays every child out at the size of its largest, so a child whose
    /// content cannot fit stretches the others with it. The session list did
    /// that to the chat: with twelve invites it no longer fitted the screen,
    /// and the chat's web view was laid out over 31,000 points tall behind it
    /// (7 October 2026). A web view that size reloads its page and then
    /// refuses every call from the app.
    func keepsOfferedHeight() -> some View {
        frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}
