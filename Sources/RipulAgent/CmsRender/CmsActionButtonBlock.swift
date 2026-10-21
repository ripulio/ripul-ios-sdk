import SwiftUI

/// Native twin of `actionButton` (ActionButtonBlock.tsx + useBlockActionRunner).
///
/// Semantics mirrored: every action type's empty state, `clearSelection`'s
/// auto-hide until its query has a selection, mutation params (the
/// mutation's paramSources, then the button's paramMap), "Waiting for
/// selection…" while a bound row is missing, the mutation's confirm message,
/// success message (or "Done — N row(s) affected") and its query refreshes.
///
/// Presentation is the system button: Filled → `.borderedProminent`,
/// Outlined → `.bordered`, Text → `.borderless`, tinted with the theme colour
/// or the authored fill; content size → `controlSize`. The confirm is a
/// system alert. The result shows as a line under the button for a few
/// seconds (the web's snackbar), a failure as an alert.
///
/// Degraded: `exportSheet` and `computeLookup` need the web grid's own
/// machinery (spreadsheet capture, Firestore lookups) and show disabled with
/// a note.
struct CmsActionButtonBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL

    @State private var running = false
    @State private var confirming = false
    @State private var result: String?
    @State private var failure: String?

    private var props: [String: CmsJSON] { runtime.resolvedProps(for: block) }
    private var actionType: String { props.string("actionType") ?? "mutation" }
    private var mutationSlug: String { props.string("mutationSlug") ?? "" }

    var body: some View {
        if let empty = emptyMessage {
            Label(empty, systemImage: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(runtime.theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(runtime.theme.divider))
        } else if !autoHidden {
            content
        }
    }

    // MARK: - Semantics

    private var emptyMessage: String? {
        switch actionType {
        case "navigatePage":
            return (props.string("targetPageSlug") ?? "").isEmpty ? "Pick a target page in the block editor." : nil
        case "openUrl":
            let url = props.string("url") ?? ""
            return url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil
                ? "Enter a web address starting https:// in the block editor." : nil
        case "switchGridView":
            return (props.string("targetGridId") ?? "").isEmpty || (props.string("targetViewId") ?? "").isEmpty
                ? "Configure a Grid ID and View in the block editor." : nil
        case "computeLookup":
            return (props.string("targetGridId") ?? "").isEmpty
                ? "Set the Grid ID of the grid whose lookup column this button computes." : nil
        case "clearSelection":
            return (props.string("clearSelectionSlug") ?? "").isEmpty ? "Pick a query to clear in the block editor." : nil
        case "mutation":
            return mutationSlug.isEmpty ? "No mutation selected. Pick one in the block editor." : nil
        default:
            return nil
        }
    }

    private var autoHidden: Bool {
        guard actionType == "clearSelection", props.bool("autoHide") ?? true else { return false }
        let slug = props.string("clearSelectionSlug") ?? ""
        return (runtime.selections[slug] ?? []).isEmpty
    }

    /// Mutation params; `.some(nil)` while a bound selection is missing.
    private var params: [String: CmsJSON]?? {
        actionType == "mutation" ? runtime.mutationParams(mutationSlug, paramMap: props.object("paramMap")) : .none
    }

    private var waiting: Bool {
        if case .some(.none) = params { return true }
        return false
    }

    private var webOnly: Bool { actionType == "exportSheet" || actionType == "computeLookup" }

    private func trigger() {
        switch actionType {
        case "navigatePage":
            if let slug = props.string("targetPageSlug") { runtime.navigate(toPage: slug) }
        case "openUrl":
            if let url = props.string("url").flatMap(URL.init(string:)) { openURL(url) }
        case "switchGridView":
            if let grid = props.string("targetGridId"), let view = props.string("targetViewId") {
                runtime.gridViewRequest = CmsRuntime.GridViewRequest(gridId: grid, viewId: view)
            }
        case "clearSelection":
            if let slug = props.string("clearSelectionSlug") { runtime.setSelectedRows(slug, rows: []) }
        case "mutation":
            let confirm = runtime.mutationDefs[mutationSlug]?.confirmMessage ?? ""
            if confirm.isEmpty { execute() } else { confirming = true }
        default:
            break
        }
    }

    private func execute() {
        let resolved: [String: CmsJSON]?
        switch params {
        case .some(.some(let p)): resolved = p
        case .some(.none): return
        case .none: resolved = nil
        }
        running = true
        Task {
            let outcome = await runtime.runMutation(mutationSlug, params: resolved)
            running = false
            switch outcome {
            case .done(_, let message):
                withAnimation { result = message }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                withAnimation { if result == message { result = nil } }
            case .failed(let message):
                failure = message
            }
        }
    }

    // MARK: - Presentation

    private var tint: Color {
        if let fill = runtime.color(props.string("backgroundColor")) { return fill }
        let theme = runtime.theme
        switch props.string("color") ?? "primary" {
        case "secondary": return theme.secondary
        case "error": return theme.error
        case "warning": return theme.warning
        case "info": return theme.info
        case "success": return theme.success
        default: return theme.primary
        }
    }

    private var labelColor: Color? {
        guard runtime.color(props.string("backgroundColor")) != nil else { return nil }
        return runtime.color(props.string("textColor")) ?? .white
    }

    private var controlSize: ControlSize {
        switch props.string("size") ?? "medium" {
        case "small": return .small
        case "large": return .large
        default: return .regular
        }
    }

    /// `fullWidth` on the web comes from the block frame's width, not a prop.
    private var fullWidth: Bool {
        let width = block.frame?.width ?? ""
        return block.frame?.size == "fill" || (!width.isEmpty && width != "hug" && width != "fit-content")
    }

    private var title: String {
        if running { return "Running…" }
        if waiting { return "Waiting for selection…" }
        return props.string("label") ?? "Submit"
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: fullWidth ? .center : .leading, spacing: 6) {
            styled(
                Button(action: trigger) {
                    HStack(spacing: 6) {
                        if running { ProgressView().controlSize(.small) }
                        Text(title)
                            .foregroundColor(labelColor)
                            .frame(maxWidth: fullWidth ? .infinity : nil)
                    }
                }
            )
            .tint(tint)
            .controlSize(controlSize)
            .disabled(running || waiting || webOnly)
            .cmsInspectorID("Cms.actionButton.button")
            if webOnly {
                Text(actionType == "exportSheet" ? "Export is available on the web." : "Computing lookups is available on the web.")
                    .font(.system(size: 12))
                    .foregroundColor(runtime.theme.textSecondary)
            }
            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(runtime.theme.success)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .alert("Confirm", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button(props.string("label") ?? "Run") { execute() }
        } message: {
            Text(runtime.mutationDefs[mutationSlug]?.confirmMessage ?? "")
        }
        .alert("Couldn't run that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func styled<B: View>(_ button: B) -> some View {
        switch props.string("variant") ?? "contained" {
        case "outlined": button.buttonStyle(.bordered)
        case "text": button.buttonStyle(.borderless)
        default: button.buttonStyle(.borderedProminent)
        }
    }
}
