import SwiftUI

/// Native twin of the web `gridViewSwitcher` block (GridViewSwitcherBlock.tsx).
/// Saved views are named AG Grid state snapshots applied to a target grid.
/// Natively the switcher publishes the picked view's state through the
/// runtime's grid-view channel; the grid twin honours the subset it can
/// (column visibility/order, sort model, row grouping — filter models
/// degrade away for now).
///
/// Presentation: one native implementation for all three web appearances
/// (tabs/pills/buttons) — the SYSTEM segmented control (UISegmentedControl
/// via Picker.segmented). First-class control by user mandate: no custom
/// chips, no hand-rolled glass — on iOS 26 the system supplies the Liquid
/// Glass appearance and sliding selection itself. The implicit "Base"
/// scratchpad is design-time only, so it never shows. Deep-link (?view=)
/// handling is a web-routing concern and doesn't apply; instead the user's
/// last-picked view persists per block instance.
struct CmsGridViewSwitcherBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var activeId: String?
    @State private var configured = false

    private var targetGridId: String { block.props.string("targetGridId") ?? "" }
    /// When on, a view may re-bind the target grid's READ query to its own
    /// `querySlug` (web parity: the toggle gates the per-view query re-bind).
    private var switchesQuery: Bool { block.props.bool("switchesQuery") ?? false }

    private struct GridView: Identifiable {
        var id: String
        var name: String
        var state: CmsJSON
        /// Optional read query this view re-binds the grid to (top-level on the
        /// persisted view, NOT in `state` — the web excludes it from the blob).
        var querySlug: String?
    }

    /// Saved views, hidden ones dropped — same runtime rule as the web.
    private var views: [GridView] {
        guard case .array(let raw) = block.props["views"] ?? .null else { return [] }
        return raw.compactMap { entry in
            guard let obj = entry.objectValue,
                  let id = obj.string("id"),
                  obj.bool("visible") != false else { return nil }
            return GridView(
                id: id,
                name: obj.string("name") ?? "View",
                state: obj["state"] ?? .null,
                querySlug: obj.string("querySlug")
            )
        }
    }

    var body: some View {
        let views = self.views
        Group {
            if views.isEmpty || targetGridId.isEmpty {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Picker("View", selection: selectionBinding(views)) {
                        ForEach(views) { view in
                            Text(view.name).tag(view.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .padding(.vertical, 2)
                    .cmsInspectorID("Cms.gridViewSwitcher.picker")
                }
            }
        }
        .onAppear { applyDefault(views) }
        // Grid-view requests (nav deep links / switchGridView actions):
        // consume the ones aimed at this switcher's target grid.
        .onReceive(runtime.$gridViewRequest) { request in
            guard let request, request.gridId == targetGridId else { return }
            runtime.gridViewRequest = nil
            if let view = self.views.first(where: { $0.id == request.viewId }) {
                apply(view)
            }
        }
    }

    private func selectionBinding(_ views: [GridView]) -> Binding<String> {
        Binding(
            get: { activeId ?? views.first?.id ?? "" },
            set: { id in
                if let view = views.first(where: { $0.id == id }) {
                    apply(view)
                }
            }
        )
    }

    private func apply(_ view: GridView) {
        activeId = view.id
        runtime.setGridViewActiveId(targetGridId, id: view.id)
        runtime.setGridViewState(targetGridId, state: view.state)
        // Per-view read-query re-bind (web parity): only when `switchesQuery`
        // is on; nil/blank reverts the grid to its base query.
        runtime.setGridQueryOverride(targetGridId, querySlug: switchesQuery ? view.querySlug : nil)
        UserDefaults.standard.set(view.id, forKey: persistenceKey)
    }

    /// Initial view: the user's last pick when it still exists, else the
    /// first visible view — twin of the web's defaultView (minus deep links).
    private func applyDefault(_ views: [GridView]) {
        guard !configured else { return }
        configured = true
        let savedId = UserDefaults.standard.string(forKey: persistenceKey)
        let target = savedId.flatMap { id in views.first(where: { $0.id == id }) } ?? views.first
        guard let view = target else { return }
        if runtime.gridViewStates[targetGridId] == nil {
            // No active view state yet — first render. Apply the saved snapshot.
            apply(view)
        } else {
            // The grid already has an active view state (set by a previous
            // render of this switcher). AnyView wrapping recreates this view on
            // every parent re-render, which would reset `configured` and
            // re-apply the original snapshot — wiping any in-flight inspector
            // edits. Skip the re-apply; just restore the picker's selection.
            activeId = view.id
        }
    }

    private var persistenceKey: String {
        "io.ripul.cms.gridView.\(runtime.cmsId).\(block.slug ?? block.id)"
    }
}
