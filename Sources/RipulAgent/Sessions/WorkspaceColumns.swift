#if os(iOS)
import SwiftUI

/// Widths are in points of usable container space, independent of device idiom.
public enum WorkspaceColumns {
    public static let sessionAndChatMinimum: CGFloat = 800
    public static let appSidebarMinimum: CGFloat = 1120
    // Measured after the app sidebar. Even a 480pt metadata pane leaves 800pt
    // for the session list and chat, so the fourth column cannot hide either.
    public static let metadataMinimum: CGFloat = 1280

    /// The app shell needs breakpoint decisions, not every intermediate pixel.
    /// Equatable geometry observation keeps live resizing out of its large body;
    /// the child layout still receives the actual, continuous size proposal.
    public struct NavigationSpace: Equatable {
        public let supportsSessionSplit: Bool
        public let supportsSidebar: Bool

        public init(width: CGFloat) {
            supportsSessionSplit = width >= sessionAndChatMinimum
            supportsSidebar = width >= appSidebarMinimum
        }
    }

    public static func pinsAppSidebar(width: CGFloat) -> Bool {
        width >= appSidebarMinimum
    }

    public static func appSidebarWidth(regularWidth: CGFloat, isPinned: Bool) -> CGFloat {
        isPinned ? regularWidth * 0.70 : regularWidth
    }

    public static func showsSessionAndChat(width: CGFloat, hasActiveChat: Bool) -> Bool {
        hasActiveChat && width >= sessionAndChatMinimum
    }

    public static func sessionListWidth(in width: CGFloat, preferred: CGFloat? = nil) -> CGFloat {
        // A dragged desktop divider must still leave a usable chat at 800pt.
        min(max(380, width - 420), min(preferred == nil ? 460 : 640, max(380, preferred ?? width * 0.40)))
    }

    public static func showsMetadata(width: CGFloat, hasActiveChat: Bool) -> Bool {
        hasActiveChat && width >= metadataMinimum
    }
}

/// Both panes remain mounted when moving between single-column navigation and
/// the two-column layout. The system cannot collapse the list independently.
struct SessionChatColumns<List: View, Chat: View>: View {
    let width: CGFloat
    let showsBoth: Bool
    let showingList: Bool
    let chatOffset: CGFloat
    let canInteractWithChat: Bool
    let list: List
    let chat: Chat
    var preferredListWidth: CGFloat? = nil
    var onResizeList: ((CGFloat) -> Void)? = nil
    @State private var resizeStart: CGFloat?

    private var listWidth: CGFloat { WorkspaceColumns.sessionListWidth(in: width, preferred: preferredListWidth) }

    var body: some View {
        ZStack(alignment: .leading) {
            list
                .frame(width: showsBoth ? listWidth : width)
                .allowsHitTesting(showsBoth || showingList)
                .accessibilityHidden(!showsBoth && !showingList)
            chat
                .frame(width: showsBoth ? max(1, width - listWidth - 1) : width)
                .modifier(SlideEffect(offset: showsBoth ? listWidth + 1 : chatOffset))
                .allowsHitTesting((showsBoth || !showingList) && canInteractWithChat)
                .accessibilityHidden(!showsBoth && showingList)
            if showsBoth {
                Divider().frame(width: 1)
                    .overlay {
                        if let onResizeList {
                            Color.clear.frame(width: 10).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if resizeStart == nil { resizeStart = listWidth }
                                        onResizeList(WorkspaceColumns.sessionListWidth(in: width,
                                            preferred: (resizeStart ?? listWidth) + value.translation.width))
                                    }
                                    .onEnded { _ in resizeStart = nil })
                        }
                    }
                    .accessibilityHidden(onResizeList == nil)
                    .accessibilityLabel("Sessions column width")
                    .accessibilityAdjustableAction { direction in
                        guard let onResizeList else { return }
                        switch direction {
                        case .increment: onResizeList(WorkspaceColumns.sessionListWidth(in: width, preferred: listWidth + 40))
                        case .decrement: onResizeList(WorkspaceColumns.sessionListWidth(in: width, preferred: listWidth - 40))
                        @unknown default: break
                        }
                    }
                    .offset(x: listWidth)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        // Keep horizontal slide-over content inside the workspace, but extend
        // the clip itself to the window's vertical edges. Otherwise the chat's
        // full-height web view is cut off behind the top and composer glass.
        .ignoresSafeArea(.container, edges: .vertical)
    }
}
#endif
