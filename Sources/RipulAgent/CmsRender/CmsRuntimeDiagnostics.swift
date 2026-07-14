import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Test-bed data inspector — live view of the CmsRuntime's query states,
/// parameter store and published selections, so a broken binding chain can be
/// pinpointed on-device (which link is waiting/erroring and what each control
/// actually published).
struct CmsRuntimeDiagnosticsView: View {
    @ObservedObject var runtime: CmsRuntime
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                Section("Navigation") {
                    Text("page: \(runtime.currentPageSlug ?? "-")  outlet: \(runtime.outletPage?.slug ?? "-")")
                        .font(.caption.monospaced())
                    Text("edgeSwipe: \(runtime.pageSidebarEdgeSwipe ? "on" : "OFF")  icon: \(runtime.pageSidebarIcon ? "on" : "off")")
                        .font(.caption.monospaced())
                    Text("slots L: \(runtime.edgeSwipeLeftSlot != nil ? "yes" : "no")  R: \(runtime.edgeSwipeRightSlot != nil ? "yes" : "no")  drawer: \(runtime.openDrawer != nil ? "open" : "closed")")
                        .font(.caption.monospaced())
                    Text("leftEdge: \(runtime.leftEdgeDebug)")
                        .font(.caption.monospaced())
                }
                Section("Queries (\(runtime.queryDefs.count) defs)") {
                    ForEach(querySlugs, id: \.self) { slug in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(slug).font(.subheadline.weight(.medium))
                                Spacer()
                                stateBadge(runtime.state(for: slug))
                            }
                            if case .waiting(let reason) = runtime.state(for: slug) {
                                Text(reason).font(.caption).foregroundColor(.orange)
                            }
                            if case .error(let message) = runtime.state(for: slug) {
                                Text(message).font(.caption).foregroundColor(.red)
                            }
                            if let def = runtime.queryDefs[slug],
                               let sources = def.paramSources, !sources.isEmpty {
                                Text("params: " + sources.keys.sorted().joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section("Parameters (\(runtime.parameters.count))") {
                    if runtime.parameters.isEmpty {
                        Text("none written").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(runtime.parameters.keys.sorted(), id: \.self) { id in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id).font(.subheadline.weight(.medium))
                            Text(CmsRuntime.stableHash(runtime.parameters[id] ?? .null))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                Section("Selections / outputs (\(runtime.selections.count))") {
                    if runtime.selections.isEmpty {
                        Text("none published").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(runtime.selections.keys.sorted(), id: \.self) { slug in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(slug).font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(runtime.selections[slug]?.count ?? 0) row(s)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let first = runtime.selections[slug]?.first {
                                Text(CmsRuntime.stableHash(first))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Runtime data")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        copyReport()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
    }

    /// Full plain-text dump of the runtime — every query state, parameter
    /// value and published selection row, ready to paste into a chat.
    private func copyReport() {
        var lines: [String] = ["── CMS runtime data ──", "", "QUERIES (\(runtime.queryDefs.count) defs)"]
        for slug in querySlugs {
            var line = "  \(slug): "
            switch runtime.state(for: slug) {
            case .idle: line += "idle"
            case .loading: line += "loading"
            case .waiting(let reason): line += "WAITING — \(reason)"
            case .ok(let result): line += "ok · \(result.rows.count) rows"
            case .error(let message): line += "ERROR — \(message)"
            }
            if let sources = runtime.queryDefs[slug]?.paramSources, !sources.isEmpty {
                line += "  [params: \(sources.keys.sorted().joined(separator: ", "))]"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("PARAMETERS (\(runtime.parameters.count))")
        for id in runtime.parameters.keys.sorted() {
            lines.append("  \(id) = \(CmsRuntime.stableHash(runtime.parameters[id] ?? .null))")
        }
        lines.append("")
        lines.append("SELECTIONS / OUTPUTS (\(runtime.selections.count))")
        for slug in runtime.selections.keys.sorted() {
            let rows = runtime.selections[slug] ?? []
            lines.append("  \(slug): \(rows.count) row(s)")
            if let first = rows.first {
                lines.append("    first: \(CmsRuntime.stableHash(first))")
            }
        }
        let text = lines.joined(separator: "\n")
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private var querySlugs: [String] {
        // Defs first (sorted), then any ad-hoc slugs that have state.
        let defs = runtime.queryDefs.keys.sorted()
        let extra = runtime.queries.keys.filter { !runtime.queryDefs.keys.contains($0) }.sorted()
        return defs + extra
    }

    @ViewBuilder
    private func stateBadge(_ state: CmsRuntime.QueryState) -> some View {
        switch state {
        case .idle:
            Text("idle").font(.caption).foregroundColor(.secondary)
        case .loading:
            Text("loading").font(.caption).foregroundColor(.blue)
        case .waiting:
            Text("waiting").font(.caption).foregroundColor(.orange)
        case .ok(let result):
            Text("ok · \(result.rows.count) rows").font(.caption).foregroundColor(.green)
        case .error:
            Text("error").font(.caption).foregroundColor(.red)
        }
    }
}
