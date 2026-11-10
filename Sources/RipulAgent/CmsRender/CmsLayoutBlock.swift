import SwiftUI

/// The `layout` block: a primitives tree (CmsPrimitives) as a page block, for
/// a screen's own composition. `query`'s first row fills its slots; a tap runs
/// through the cards' action rules (CmsRowActionRunner), on the row its node reads.
struct CmsLayoutBlockView: View {
    let block: CmsBlock
    @EnvironmentObject private var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL
    @StateObject private var runner = CmsRowActionRunner()

    var body: some View {
        let props = runtime.resolvedProps(for: block)
        let query = props.string("query").flatMap { $0.isEmpty ? nil : $0 }
        Group {
            if let root = props["root"], root.objectValue != nil {
                CmsPrimitiveTree(tree: root, row: query.flatMap(firstRow)) { action, row in
                    runner.perform(action, label: "OK", row: row, query: query, runtime: runtime) { openURL($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: query) { if let query { runtime.ensureLoaded(query) } }
        .modifier(CmsRowActionRunnerPresenter(runner: runner, runtime: runtime))
        .cmsInspectorID("Cms.layout")
    }

    private func firstRow(_ query: String) -> [String: CmsJSON]? {
        if case .ok(let result) = runtime.state(for: query) { return result.rows.first }
        return nil
    }
}
