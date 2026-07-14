import SwiftUI

/// Native twin of `pageOutlet` (PageOutletBlock.tsx) — the shell pattern's
/// routed-content region. When the definition designates a shell page
/// (`cms.shellPageId`), the shell renders as persistent chrome (nav
/// drawers, top bar) and the navigated page renders HERE, crossfading on
/// route changes. The runtime (queries, selections, parameters) is shared
/// across shell and routed pages, matching the portal-scoped web contexts.
struct CmsPageOutletBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        if let page = runtime.outletPage, let blocks = page.blocks {
            CmsBlockContainerView(container: blocks)
                // Fresh identity per routed page: block onAppear hooks
                // (query loads, edge-swipe registrations) fire per page.
                .id(page.id)
                .transition(.opacity)
        } else {
            Text(block.props.string("emptyMessage").flatMap { $0.isEmpty ? nil : $0 }
                 ?? "Page content renders here")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
    }
}
