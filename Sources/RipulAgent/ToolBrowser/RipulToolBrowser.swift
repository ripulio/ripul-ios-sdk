import SwiftUI

// ---------------------------------------------------------------------------
// Tool browser — a tree of progressive-discovery categories with the chat's
// per-category switch on each node, the member tools underneath, and a
// drill-in to any tool's description and schema.
//
// Two layers, on purpose:
//   • `RipulToolBrowserView` is pure presentation over a `RipulToolInventory`
//     plus callbacks. Embed it anywhere an inventory can be supplied.
//   • `RipulToolBrowser` is the self-loading wrapper for a chat: it fetches the
//     inventory through the bridge, writes switch changes back, and reloads.
// The session metadata panel embeds the wrapper today; nothing in either layer
// assumes that host, so the same component can move to a sheet, a settings
// page or a tool picker without change.
// ---------------------------------------------------------------------------

/// Self-loading tool browser for one chat.
@available(iOS 15.0, macOS 13.0, *)
public struct RipulToolBrowser: View {
    let bridge: AgentBridge
    let chatId: String

    @State private var inventory: RipulToolInventory?
    @State private var loading = false
    @State private var error: String?
    @State private var savingCategory: String?

    public init(bridge: AgentBridge, chatId: String) {
        self.bridge = bridge
        self.chatId = chatId
    }

    public var body: some View {
        Group {
            if let inventory {
                RipulToolBrowserView(
                    inventory: inventory,
                    loading: loading,
                    savingCategory: savingCategory,
                    onToggleCategory: { name, on in await toggle(name, enabled: on) },
                    onRefresh: { await load() }
                )
            } else if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                        .font(.caption)
                        .uiKitIdentifier("ToolBrowser.retry")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading tools…").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task(id: chatId) { await load() }
        .uiKitIdentifier("ToolBrowser")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let inv = await bridge.getChatToolInventory(chatId: chatId) {
            inventory = inv
            error = nil
        } else if inventory == nil {
            error = "Could not load the tool list — page may not be ready."
        }
    }

    private func toggle(_ name: String, enabled: Bool) async {
        guard var inv = inventory, let idx = inv.categories.firstIndex(where: { $0.name == name }) else { return }
        // Optimistic: flip the switch and status now so the row does not snap
        // back while the descriptor write and the re-list land.
        inv.categories[idx].enabled = enabled
        inv.categories[idx].status = enabled ? .collapsed : .hidden
        inventory = inv
        savingCategory = name
        _ = await bridge.setChatToolCategories(chatId: chatId, disabled: inv.disabledCategoryNames)
        savingCategory = nil
        await load()
    }
}

/// Presentation-only tool browser. Supply an inventory and callbacks.
@available(iOS 15.0, macOS 13.0, *)
public struct RipulToolBrowserView: View {
    public let inventory: RipulToolInventory
    public let loading: Bool
    public let savingCategory: String?
    public let onToggleCategory: (String, Bool) async -> Void
    public let onRefresh: (() async -> Void)?

    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var otherExpanded = false
    @State private var selectedTool: RipulToolInventory.Tool?

    public init(
        inventory: RipulToolInventory,
        loading: Bool = false,
        savingCategory: String? = nil,
        onToggleCategory: @escaping (String, Bool) async -> Void,
        onRefresh: (() async -> Void)? = nil
    ) {
        self.inventory = inventory
        self.loading = loading
        self.savingCategory = savingCategory
        self.onToggleCategory = onToggleCategory
        self.onRefresh = onRefresh
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private func matches(_ tool: RipulToolInventory.Tool) -> Bool {
        query.isEmpty || tool.name.lowercased().contains(query) || tool.description.lowercased().contains(query)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            vantageLine
            ForEach(inventory.categories) { category in
                categoryNode(category)
            }
            if !inventory.uncategorized.isEmpty {
                otherNode
            }
        }
        .sheet(item: $selectedTool) { tool in
            RipulToolDetailView(tool: tool)
        }
        .uiKitIdentifier("ToolBrowser.view")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Search tools…", text: $search)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .uiKitIdentifier("ToolBrowser.search")
            Text("\(inventory.resolvedNames.count) live · \(inventory.totalToolCount) total")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            if let onRefresh {
                Button {
                    Task { await onRefresh() }
                } label: {
                    if loading {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .uiKitIdentifier("ToolBrowser.refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: Vantage

    /// Says whose truth this is. Fetched from the chat's host = what the CLI is
    /// actually served; computed here = this device's approximation.
    @ViewBuilder
    private var vantageLine: some View {
        if let v = inventory.vantage {
            HStack(spacing: 5) {
                Image(systemName: v.remote ? "checkmark.seal" : (v.fallback == nil ? "iphone" : "exclamationmark.triangle"))
                    .font(.caption2)
                if v.remote {
                    Text("Live from \(v.machineName) — what the session is served")
                } else if let fallback = v.fallback {
                    Text("As seen from this \(v.hostLabel) — \(fallback)")
                } else {
                    Text("As seen from this \(v.hostLabel)")
                }
            }
            .font(.caption2)
            .foregroundStyle(v.remote ? Color.secondary : (v.fallback == nil ? Color.secondary : Color.orange))
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .uiKitIdentifier("ToolBrowser.vantage")
        }
    }

    // MARK: Category node

    @ViewBuilder
    private func categoryNode(_ category: RipulToolInventory.Category) -> some View {
        let visibleTools = category.tools.filter(matches)
        let catalogOnly = category.catalogOnly.filter(matches)
        let declared = category.unresolvedDeclared.filter { query.isEmpty || $0.lowercased().contains(query) }
        let anyMatch = !visibleTools.isEmpty || !catalogOnly.isEmpty || !declared.isEmpty
        let isOpen = expanded.contains(category.name) || (!query.isEmpty && anyMatch)
        // A search that matches nothing under a category hides the node too —
        // the switch is still reachable by clearing the search.
        if query.isEmpty || anyMatch {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expanded.contains(category.name) { expanded.remove(category.name) } else { expanded.insert(category.name) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(category.label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(category.enabled ? .primary : .secondary)
                                    .lineLimit(1)
                                Text(categorySubtitle(category))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("ToolBrowser.category.expand")

                    Toggle("", isOn: Binding(
                        get: { category.enabled },
                        set: { on in Task { await onToggleCategory(category.name, on) } }
                    ))
                    .labelsHidden()
                    .disabled(savingCategory != nil)
                    .uiKitIdentifier("ToolBrowser.category.switch")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)

                if isOpen {
                    ForEach(visibleTools) { tool in
                        toolRow(tool, dimmed: !category.enabled)
                    }
                    ForEach(catalogOnly) { tool in
                        toolRow(tool, dimmed: true)
                    }
                    ForEach(declared, id: \.self) { name in
                        declaredRow(name)
                    }
                    if !category.declaredPatterns.isEmpty {
                        Text("also matches: " + category.declaredPatterns.joined(separator: "  "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.leading, 36)
                            .padding(.trailing, 16)
                            .padding(.vertical, 3)
                    }
                    if !anyMatch {
                        Text("No tools in this category right now.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 36)
                            .padding(.vertical, 4)
                    }
                }
                Divider().padding(.leading, 16)
            }
            .uiKitIdentifier("ToolBrowser.category")
        }
    }

    private func categorySubtitle(_ category: RipulToolInventory.Category) -> String {
        let count = category.tools.count == 1 ? "1 tool" : "\(category.tools.count) tools"
        let catalog = category.catalogOnly.isEmpty ? "" : " · \(category.catalogOnly.count) web agent only"
        let declared = (category.unresolvedDeclared.isEmpty ? "" : " · \(category.unresolvedDeclared.count) declared, not reachable from here")
        let declaredAll = catalog + declared
        switch category.status {
        case .hidden: return "\(count) · off for this chat" + declaredAll
        case .collapsed: return "\(count) · folded into one stub" + declaredAll
        case .expanded: return "\(count) · revealed to the model" + declaredAll
        }
    }

    /// A member the category definition names that this vantage could not
    /// resolve — typically a device_ tool seen only from the Mac.
    private func declaredRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.5))
                .frame(width: 14)
            Text(name)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("declared")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.leading, 36)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .uiKitIdentifier("ToolBrowser.declared")
    }

    // MARK: Uncategorised node

    private var otherNode: some View {
        let visibleTools = inventory.uncategorized.filter(matches)
        let isOpen = otherExpanded || (!query.isEmpty && !visibleTools.isEmpty)
        return VStack(spacing: 0) {
            if query.isEmpty || !visibleTools.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { otherExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Always on").font(.caption.weight(.medium)).lineLimit(1)
                            Text(inventory.uncategorized.count == 1 ? "1 tool · no category" : "\(inventory.uncategorized.count) tools · no category")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .uiKitIdentifier("ToolBrowser.other.expand")

                if isOpen {
                    ForEach(visibleTools) { tool in
                        toolRow(tool, dimmed: false)
                    }
                }
            }
        }
        .uiKitIdentifier("ToolBrowser.other")
    }

    // MARK: Tool row

    private func toolRow(_ tool: RipulToolInventory.Tool, dimmed: Bool) -> some View {
        Button {
            selectedTool = tool
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tool.visibleNow ? "eye" : "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(tool.visibleNow ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 14)
                Text(tool.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(tool.absentReasonLabel ?? tool.originLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 36)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .uiKitIdentifier("ToolBrowser.tool")
    }
}
