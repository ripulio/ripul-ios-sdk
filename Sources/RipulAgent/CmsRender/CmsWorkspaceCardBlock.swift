import SwiftUI

/// The workspace card: a brand-gradient mark with the initials beside a name
/// and optional subtitle. With several records in its source query it is a
/// native `Menu` of them (plus its page); otherwise it opens its page.
/// Shared by the Sidebar Nav's header (`headerTitle`…) and the standalone
/// `workspaceCard` block (`title`…), as on the web (SidebarNavBlock's
/// `WorkspaceCard`).
struct CmsWorkspaceCard: View {
    struct Keys {
        var title: String
        var subtitle: String
        var initials: String
        var source: String
        var target: String

        static let sidebarHeader = Keys(title: "headerTitle", subtitle: "headerSubtitle", initials: "headerInitials",
                                        source: "headerQuerySlug", target: "headerTargetPageSlug")
        static let block = Keys(title: "title", subtitle: "subtitle", initials: "initials",
                                source: "querySlug", target: "targetPageSlug")
    }

    let block: CmsBlock
    let keys: Keys
    /// `hug` sizes the card to its name; otherwise it takes the width given.
    var hug = false
    @EnvironmentObject var runtime: CmsRuntime

    private var title: String? {
        guard let title = runtime.resolveString(block: block, propKey: keys.title),
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return title
    }

    /// Two-letter mark: authored initials, else the title's (any token still
    /// unresolved is ignored, as on the web).
    private func initials(for title: String) -> String {
        if let authored = block.props.string(keys.initials)?.trimmingCharacters(in: .whitespaces),
           !authored.isEmpty {
            return String(authored.prefix(3))
        }
        let words = title.replacing(#/@[A-Za-z_]\w*\.[A-Za-z_]\w*/#, with: " ")
            .split(whereSeparator: \.isWhitespace)
        if words.count == 1 { return String(words[0].prefix(2)).uppercased() }
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var source: String? {
        block.props.string(keys.source).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var sourceRows: [[String: CmsJSON]] {
        guard let source, case .ok(let result) = runtime.state(for: source) else { return [] }
        return result.rows
    }

    /// The card's text for one record of the source: its `@source.column`
    /// tokens read that row, other tokens the current selections.
    private func text(_ propKey: String, row: [String: CmsJSON]) -> String {
        guard let source, let raw = block.props.string(propKey) else { return "" }
        if let binding = block.bindings?[propKey], binding.querySlug == source {
            return row[binding.column]?.displayString ?? ""
        }
        return runtime.resolveTemplate(raw.replacingOccurrences(of: "@\(source).", with: "@"), rowContext: row)
    }

    /// Land on the first record when nothing is selected yet
    /// (web: useRecordCursor autoSelectFirst).
    private func anchorSource() {
        guard let source else { return }
        runtime.ensureLoaded(source)
        if runtime.selectedRow(source) == nil, let first = sourceRows.first {
            runtime.setSelectedRows(source, rows: [first])
        }
    }

    private static let unresolvedToken = #/@[A-Za-z_]\w*\.[A-Za-z_]\w*/#

    var body: some View {
        if let title {
            let subtitle = runtime.resolveString(block: block, propKey: keys.subtitle)
                .flatMap { $0.isEmpty ? nil : $0 }
            let target = block.props.string(keys.target).flatMap { $0.isEmpty ? nil : $0 }
            // Tokens whose row isn't selected yet show as a placeholder, never raw.
            let pending = title.contains(Self.unresolvedToken) || (subtitle?.contains(Self.unresolvedToken) ?? false)
            let rows = sourceRows
            let switchable = rows.count > 1
            let card = HStack(spacing: 10) {
                Text(initials(for: title))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(runtime.theme.primaryContrast)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(runtime.theme.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(runtime.theme.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(runtime.theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if !hug { Spacer(minLength: 0) }
                if switchable {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else if target != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .redacted(reason: pending ? .placeholder : [])
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(runtime.theme.surfaceMuted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(runtime.theme.divider, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())

            Group {
                if switchable, let source {
                    let current = runtime.selectedRow(source)
                    Menu { MenuIcons {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            Button {
                                runtime.setSelectedRows(source, rows: [row])
                            } label: {
                                let label = text(keys.title, row: row)
                                if current == row {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                        if let target {
                            Divider()
                            Button("Settings") { runtime.navigate(toPage: target, viewRef: nil) }
                        }
                    }} label: { card }
                    .buttonStyle(.plain)
                    .cmsInspectorID("Cms.workspaceCard.menu")
                } else if let target {
                    Button { runtime.navigate(toPage: target, viewRef: nil) } label: { card }
                        .buttonStyle(.plain)
                        .cmsInspectorID("Cms.workspaceCard.card")
                } else {
                    card.cmsInspectorID("Cms.workspaceCard.card")
                }
            }
            .fixedSize(horizontal: hug, vertical: false)
            .frame(maxWidth: hug ? nil : .infinity, alignment: .leading)
            .task(id: rows.count) { anchorSource() }
        }
    }
}

/// Native twin of `workspaceCard` (WorkspaceCardBlock.tsx): the card on its
/// own, saying which record a page is about and switching between records.
struct CmsWorkspaceCardBlockView: View {
    let block: CmsBlock

    var body: some View {
        CmsWorkspaceCard(block: block, keys: .block, hug: (block.props.string("width") ?? "hug") != "fill")
    }
}
