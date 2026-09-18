#if os(iOS)
import SwiftUI

/// Keeps host chrome out of the docked metadata pane on wide layouts.
public struct RipulMetadataColumnWidthKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// An inline column, never a modal presentation. Keep content in one structural
/// position while traits change so resizing cannot strand an inspector sheet.
struct DockedMetadataPane<Panel: View>: ViewModifier {
    let panel: Panel
    var isPresented: Bool? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var preferredWidth: CGFloat = 340
    @State private var resizeStart: CGFloat?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let maximumWidth = max(280, min(480, geometry.size.width - 560))
            let paneWidth = min(preferredWidth, maximumWidth)
            HStack(spacing: 0) {
                content
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                if isPresented ?? (sizeClass == .regular) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .overlay {
                            Color.clear
                                .frame(width: 10)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if resizeStart == nil { resizeStart = paneWidth }
                                            preferredWidth = min(maximumWidth, max(280, (resizeStart ?? paneWidth) - value.translation.width))
                                        }
                                        .onEnded { _ in resizeStart = nil }
                                )
                        }
                        .accessibilityLabel("Metadata column width")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: preferredWidth = min(maximumWidth, paneWidth + 40)
                            case .decrement: preferredWidth = max(280, paneWidth - 40)
                            @unknown default: break
                            }
                        }
                    panel
                        .frame(width: paneWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .preference(key: RipulMetadataColumnWidthKey.self, value: paneWidth + 1)
                }
            }
        }
        // The previous inspector hosting controller supplied this opaque surface.
        // Compact navigation keeps the app sidebar mounted behind the chat.
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(.container))
        .onChange(of: sizeClass) { _, _ in resizeStart = nil }
        #if targetEnvironment(macCatalyst)
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }
}
#endif
