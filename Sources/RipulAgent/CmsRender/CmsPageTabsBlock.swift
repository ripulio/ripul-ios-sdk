import SwiftUI

/// Native twin of `pageTabs` (PageTabsBlock.tsx): tabs that show one set of
/// this page's own blocks at a time. The closed tabs' blocks stay mounted,
/// hidden (so they keep what they loaded and other blocks still reach them),
/// a tab may float a chat as the floating ask button, and a tab may show a
/// count of a query's rows (or those whose column equals a value).
///
/// Presentation: the system segmented control, the count in the label. The
/// open tab is remembered per site and block, as the web keeps it per browser.
///
/// Not yet native: another block opening the tab that holds a block
/// (`openTabHolding`, e.g. "View Activity" in a report).
struct CmsPageTabsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var active = 0
    @State private var restored = false

    private struct Tab {
        var label: String
        var blocks: [String]
        var floats: [String]
        var countQuery: String?
        var countColumn: String?
        var countEquals: String?
    }

    private static func refs(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var tabs: [Tab] {
        guard case .array(let raw) = block.props["tabs"] ?? .null else { return [] }
        return raw.compactMap { entry in
            guard let t = entry.objectValue, let label = t.string("label"), !label.isEmpty else { return nil }
            return Tab(
                label: label,
                blocks: Self.refs(t.string("blocks")),
                floats: Self.refs(t.string("floatBlocks")),
                countQuery: t.string("countQuerySlug").flatMap { $0.isEmpty ? nil : $0 },
                countColumn: t.string("countColumn").flatMap { $0.isEmpty ? nil : $0 },
                countEquals: t.string("countEquals")
            )
        }
    }

    private var owner: String { block.slug ?? block.id }
    private var storageKey: String { "ripul:pageTabs:\(runtime.cmsId):\(owner)" }

    private func count(_ tab: Tab) -> Int? {
        guard let slug = tab.countQuery, case .ok(let result) = runtime.state(for: slug) else { return nil }
        guard let column = tab.countColumn else { return result.rows.count }
        let want = (tab.countEquals ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return result.rows.filter {
            ($0[column]?.displayString ?? "").trimmingCharacters(in: .whitespaces).lowercased() == want
        }.count
    }

    private func label(_ tab: Tab) -> String {
        guard let n = count(tab), n > 0 else { return tab.label }
        return "\(tab.label) (\(n > 99 ? "99+" : "\(n)"))"
    }

    var body: some View {
        let tabs = self.tabs
        if tabs.isEmpty {
            Text("Add tabs, each naming the blocks it shows.")
                .font(.system(size: 13))
                .foregroundColor(runtime.theme.textSecondary)
        } else {
            Picker("", selection: Binding(get: { min(active, tabs.count - 1) }, set: choose)) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Text(label(tab)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .cmsInspectorID("Cms.pageTabs.picker")
            .onAppear {
                if !restored {
                    restored = true
                    active = UserDefaults.standard.integer(forKey: storageKey)
                }
                for tab in tabs { if let q = tab.countQuery { runtime.ensureLoaded(q) } }
                publish(tabs)
            }
            .onChange(of: active) { _ in publish(tabs) }
            .onDisappear {
                runtime.setTabsHidden(owner, [])
                runtime.setTabsFloating(owner, [])
            }
        }
    }

    private func choose(_ index: Int) {
        active = index
        UserDefaults.standard.set(index, forKey: storageKey)
    }

    /// Hide the other tabs' blocks (not those the open tab also shows) and
    /// float the open tab's chat.
    private func publish(_ tabs: [Tab]) {
        let index = min(active, tabs.count - 1)
        let open = Set(tabs[index].blocks)
        let hidden = tabs.enumerated().flatMap { $0.offset == index ? [] : $0.element.blocks }.filter { !open.contains($0) }
        runtime.setTabsHidden(owner, Set(hidden))
        runtime.setTabsFloating(owner, runtime.isDesignMode ? [] : Set(tabs[index].floats))
    }
}
