import SwiftUI

// A section of a site with a shell of its own, in a CMS app: Sandsend's admin
// pages each name `admin-shell` as their shell, a sidebar of the admin pages.
// On the website that sidebar sits beside each admin page. `CmsAppView` draws
// no page's shell, so in the app the sidebar becomes what an iOS app has for
// the same thing: a list of the section's pages (as Settings lists its panes),
// pushed onto the tab the person is in, with each page pushed from it. Opening
// an admin page from anywhere (More's Admin row, a link) pushes the list first,
// so Back from the page is the section's list, and Back again where they were.
//
// Who sees what is the website's: the sidebar's items are filtered by role as
// the web filters them, and a page the person cannot open is not listed.

/// The rules, kept apart from SwiftUI so they can be tested.
enum CmsAppSection {
    /// The section shell a page opens under: its own shell when that is not
    /// the site's shell, it does not hide its shell, and that shell has a
    /// sidebar to list. Nil for every other page.
    static func shell(for slug: String, pages: [CmsPage], siteShellId: String?) -> CmsPage? {
        guard let page = pages.first(where: { $0.slug == slug }), page.hideShell != true,
              let shellId = page.shellPageId, shellId != siteShellId, shellId != page.id,
              let shell = pages.first(where: { $0.id == shellId }),
              sidebar(of: shell) != nil else { return nil }
        return shell
    }

    /// Whether a page is a section shell (drawn as the list, never as a page).
    static func isSectionShell(_ page: CmsPage, siteShellId: String?) -> Bool {
        guard page.id != siteShellId, sidebar(of: page) != nil, case .sidebar? = page.blocks else { return false }
        return true
    }

    /// The shell's sidebar: its first `sidebarNav`.
    static func sidebar(of shell: CmsPage) -> CmsBlock? {
        shell.blocks?.allBlocks().first { $0.type == "sidebarNav" }
    }

    /// The list's title: the sidebar's own header title, else its first heading, else the shell's title.
    static func title(of shell: CmsPage) -> String {
        guard let sidebar = sidebar(of: shell) else { return shell.title }
        if let header = sidebar.props.string("headerTitle")?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            return header
        }
        return CmsNavItem.decodeList(sidebar.props["items"]).first(where: \.heading)?.label ?? shell.title
    }

    struct Group: Equatable {
        var heading: String?
        var rows: [Row]
    }

    struct Row: Equatable {
        var label: String
        var icon: String?
        var pageSlug: String
    }

    /// The sidebar's links this person can open, grouped under its headings. An
    /// embedded block (the account avatar) is left out: the app has its own
    /// account and sign-out. Items at the end (`align: 'end'`, "View the site")
    /// form a last group of their own.
    static func groups(of shell: CmsPage, membership: CmsPortalMembership?, canDesign: Bool,
                       openableSlugs: Set<String>) -> [Group] {
        guard let sidebar = sidebar(of: shell) else { return [] }
        let items = CmsNavItem.visible(CmsNavItem.decodeList(sidebar.props["items"]), membership: membership, canDesign: canDesign)
        func flatten(_ items: [CmsNavItem]) -> [CmsNavItem] {
            items.flatMap { [$0] + flatten($0.children) }
        }
        var groups: [Group] = []
        var end = Group(heading: nil, rows: [])
        for item in flatten(items) where item.embed == nil {
            if item.heading {
                groups.append(Group(heading: item.label, rows: []))
                continue
            }
            guard let slug = item.targetPageSlug, openableSlugs.contains(slug), item.actionType == "link" else { continue }
            let row = Row(label: item.label, icon: item.icon, pageSlug: slug)
            if item.align == "end" {
                end.rows.append(row)
            } else if groups.isEmpty {
                groups.append(Group(heading: nil, rows: [row]))
            } else {
                groups[groups.count - 1].rows.append(row)
            }
        }
        if !end.rows.isEmpty { groups.append(end) }
        return groups.filter { !$0.rows.isEmpty }
    }
}

#if os(iOS)
/// The section's list: the sidebar's pages as rows, each pushed on this tab.
struct CmsAppSectionListView: View {
    let shell: CmsPage
    let openableSlugs: Set<String>
    /// A row whose page is a tab's first page (the sidebar's "View the site")
    /// goes there instead of being pushed.
    let open: (String) -> Void
    let isTabRoot: (String) -> Bool
    @ObservedObject var runtime: CmsRuntime

    var body: some View {
        let groups = CmsAppSection.groups(of: shell, membership: runtime.membership,
                                          canDesign: runtime.canDesign, openableSlugs: openableSlugs)
        List {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.rows, id: \.pageSlug) { row in
                        if isTabRoot(row.pageSlug) {
                            Button { open(row.pageSlug) } label: { label(row) }
                                .tint(.ripul(.text))
                        } else {
                            NavigationLink(value: CmsAppRoute(pageSlug: row.pageSlug)) { label(row) }
                        }
                    }
                } header: {
                    if let heading = group.heading { Text(heading) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(CmsAppSection.title(of: shell))
        .navigationBarTitleDisplayMode(.large)
        .cmsInspectorID("Cms.appSection.list")
    }

    @ViewBuilder
    private func label(_ row: CmsAppSection.Row) -> some View {
        if let symbol = CmsNavIcon.symbol(for: row.icon) {
            Label(row.label, systemImage: symbol)
        } else {
            Text(row.label)
        }
    }
}
#endif
