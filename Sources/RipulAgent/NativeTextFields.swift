#if os(iOS)
import SwiftUI

enum NativeTextDraftError: LocalizedError {
    case noRemoteTheme
    var errorDescription: String? { "This app needs an app-wide remote theme connection before saving text drafts." }
}

/// The existing native adapters use the same assignment editor as authored text.
@MainActor
struct NativeTextFields: View {
    let target: NativeTextTarget
    let savesExplicitly: Bool
    var body: some View { TextPropertyRow(target: .native(target)) }
}
#endif
