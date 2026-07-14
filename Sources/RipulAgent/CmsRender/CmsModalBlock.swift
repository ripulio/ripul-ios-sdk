import SwiftUI

/// Native twin of `modal` (ModalBlock.tsx) — a selection-driven container:
/// it opens when the watched query has a selected row and dismissing it
/// (any route) CLEARS that selection, so visibility is pure shared-selection
/// state. Children render inside with the full shared runtime, so an
/// embedded fieldGrid/detailHeader binds to the same row for free.
///
/// Presentation by platform idiom, not the web's variant names:
///  - `dialog` and `drawer(bottom)` → a native SHEET with medium/large
///    detents (the iOS record-detail surface; `maxWidth` is the sheet's own
///    business per platform).
///  - `drawer(left/right)` → the page-level drawer overlay (same spring,
///    scrim, drag-dismiss as the sidebars), authored `drawerWidth` capped
///    to the viewport, title + close header.
///  - `drawerNonModal`/`push` (the docked resizable desktop side panel)
///    degrades to the modal drawer at phone width.
/// `backdropCloses: false` disables interactive dismissal (sheet swipe /
/// scrim tap still shows the explicit close).
struct CmsModalBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var sheetPresented = false

    private var watchSlug: String { block.props.string("watchQuerySlug") ?? "" }
    private var hasSelection: Bool { !(runtime.selections[watchSlug] ?? []).isEmpty }
    private var title: String { block.props.string("title") ?? "Edit record" }
    private var backdropCloses: Bool { block.props.bool("backdropCloses") ?? true }
    private var children: CmsPageBlocks {
        block.children ?? .list(items: [], frame: nil)
    }
    /// Sheet for dialog + bottom drawer; overlay drawer for left/right.
    private var usesSheet: Bool {
        let variant = block.props.string("variant") ?? "dialog"
        return variant != "drawer" || (block.props.string("drawerAnchor") ?? "right") == "bottom"
    }

    var body: some View {
        // In-flow but invisible — the block IS its presentation.
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { sync(hasSelection) }
            .onChange(of: hasSelection) { has in sync(has) }
            .sheet(isPresented: $sheetPresented, onDismiss: clearSelection) {
                sheetBody
            }
    }

    private func sync(_ has: Bool) {
        guard !watchSlug.isEmpty else { return }
        if usesSheet {
            if sheetPresented != has { sheetPresented = has }
        } else if has {
            guard runtime.openDrawer == nil else { return }
            let edge: CmsRuntime.DrawerRequest.Edge =
                (block.props.string("drawerAnchor") ?? "right") == "left" ? .leading : .trailing
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                runtime.openDrawer = .init(
                    edge: edge,
                    slot: children,
                    title: title,
                    width: block.props.double("drawerWidth").map { CGFloat($0) } ?? 440,
                    onDismiss: clearSelection
                )
            }
        } else if runtime.openDrawer?.slot == children {
            // Selection cleared elsewhere (e.g. a detailHeader back) — take
            // our drawer down without re-firing the dismiss hook's clear.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                runtime.openDrawer = nil
            }
        }
    }

    private func clearSelection() {
        guard !watchSlug.isEmpty else { return }
        if !(runtime.selections[watchSlug] ?? []).isEmpty {
            runtime.setSelectedRows(watchSlug, rows: [])
        }
    }

    private var sheetBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    sheetPresented = false
                    clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if CmsDrawerOverlay.containsFill(children) {
                CmsBlockContainerView(container: children)
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    CmsBlockContainerView(container: children)
                        .padding(16)
                }
            }
        }
        .background(runtime.theme.paper.ignoresSafeArea())
        .environmentObject(runtime)
        .modifier(CmsModalSheetChrome(backdropCloses: backdropCloses))
    }
}

/// Sheet chrome: detents on iOS 16+, interactive-dismiss gating everywhere.
private struct CmsModalSheetChrome: ViewModifier {
    let backdropCloses: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            content
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(!backdropCloses)
        } else {
            content
                .interactiveDismissDisabled(!backdropCloses)
        }
    }
}
