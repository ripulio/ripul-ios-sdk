#if os(iOS)
import SwiftUI

/// Widths are in points of usable container space, independent of device idiom.
public enum WorkspaceColumns {
    public static let sessionAndChatMinimum: CGFloat = 800
    public static let appSidebarMinimum: CGFloat = 1120
    /// Width at which a sidebar stops floating over content and locks beside
    /// it. Lower than `appSidebarMinimum` on purpose: that one also has to fit
    /// an 800pt session-and-chat split, whereas locking a ~281pt sidebar only
    /// needs a usable content column after it. 820 pins an 11-inch iPad in
    /// portrait (834pt), which is where the platform's own apps pin.
    public static let sidebarTileMinimum: CGFloat = 820
    // Measured after the app sidebar. Even a 480pt metadata pane leaves 800pt
    // for the session list and chat, so the fourth column cannot hide either.
    public static let metadataMinimum: CGFloat = 1280

    /// The app shell needs breakpoint decisions, not every intermediate pixel.
    /// Equatable geometry observation keeps live resizing out of its large body;
    /// the child layout still receives the actual, continuous size proposal.
    public struct NavigationSpace: Equatable {
        public let supportsSessionSplit: Bool
        public let supportsSidebar: Bool
        /// The sidebar should sit beside content rather than over it.
        public let tilesSidebar: Bool

        public init(width: CGFloat) {
            supportsSessionSplit = width >= sessionAndChatMinimum
            supportsSidebar = width >= appSidebarMinimum
            tilesSidebar = width >= sidebarTileMinimum
        }
    }

    public static func pinsAppSidebar(width: CGFloat) -> Bool {
        width >= appSidebarMinimum
    }

    public static func tilesSidebar(width: CGFloat) -> Bool {
        width >= sidebarTileMinimum
    }

    public static func appSidebarWidth(regularWidth: CGFloat, isPinned: Bool) -> CGFloat {
        isPinned ? regularWidth * 0.70 : regularWidth
    }

    public static func showsSessionAndChat(width: CGFloat, hasActiveChat: Bool) -> Bool {
        hasActiveChat && width >= sessionAndChatMinimum
    }

    public static func sessionListWidth(in width: CGFloat, preferred: CGFloat? = nil) -> CGFloat {
        // A dragged divider must still leave a usable chat at 800pt.
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
    @GestureState private var resizeStart: CGFloat?
    @Namespace private var resizeCoordinateSpace

    private var listWidth: CGFloat { WorkspaceColumns.sessionListWidth(in: width, preferred: preferredListWidth) }

    var body: some View {
        ZStack(alignment: .leading) {
            list
                .frame(width: showsBoth ? listWidth : width)
                .allowsHitTesting(showsBoth || showingList)
                .accessibilityHidden(!showsBoth && !showingList)
            chat
                .frame(width: showsBoth ? max(1, width - listWidth - 1) : width)
                // Window-anchored controls belong to this pane, including while
                // its retained chat slides offscreen behind the session list.
                .clipped()
                .modifier(SlideEffect(offset: showsBoth ? listWidth + 1 : chatOffset))
                .allowsHitTesting((showsBoth || !showingList) && canInteractWithChat)
                .accessibilityHidden(!showsBoth && showingList)
            if showsBoth {
                Divider().frame(width: 1)
                    .overlay {
                        if let onResizeList {
                            ZStack {
                                Color.clear
                                #if !targetEnvironment(macCatalyst)
                                Capsule()
                                    .fill(Color.secondary.opacity(resizeStart == nil ? 0.4 : 0.8))
                                    .frame(width: 4, height: 36)
                                #endif
                            }
                            #if targetEnvironment(macCatalyst)
                            .frame(width: 10)
                            #else
                            .frame(width: 44)
                            #endif
                            .contentShape(Rectangle())
                                // Measure in the stationary column container,
                                // not in the divider that follows the finger.
                                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(resizeCoordinateSpace))
                                    .updating($resizeStart) { _, start, _ in
                                        if start == nil { start = listWidth }
                                    }
                                    .onChanged { value in
                                        onResizeList(WorkspaceColumns.sessionListWidth(in: width,
                                            preferred: (resizeStart ?? listWidth) + value.translation.width))
                                    })
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityHidden(onResizeList == nil)
                    .accessibilityLabel("Sessions column width")
                    .accessibilityValue("\(Int(listWidth)) points")
                    .accessibilityIdentifier("SessionChatColumns.divider")
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
        .coordinateSpace(name: resizeCoordinateSpace)
        .frame(width: width, alignment: .leading)
        .clipped()
        // Keep horizontal slide-over content inside the workspace, but extend
        // the clip itself to the window's vertical edges. Otherwise the chat's
        // full-height web view is cut off behind the top and composer glass.
        .ignoresSafeArea(.container, edges: .vertical)
    }
}
#endif
