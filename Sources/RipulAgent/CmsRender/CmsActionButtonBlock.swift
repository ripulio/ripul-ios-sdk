import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Native twin of `actionButton` (ActionButtonBlock.tsx + useBlockActionRunner).
///
/// Semantics mirrored: every action type's empty state, `clearSelection`'s
/// auto-hide until its query has a selection, mutation params (the
/// mutation's paramSources, then the button's paramMap), "Waiting for
/// selection…" while a bound row is missing, the mutation's confirm message,
/// success message (or "Done — N row(s) affected") and its query refreshes.
/// A mutation whose action contract names inputs nothing on the page
/// supplies asks for them first in a sheet (`CmsActionInputSheet`).
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
    /// How the button is drawn: the block's own look, or a smaller chrome
    /// another block gives an action of its own (a choice list's row action
    /// and add row, a section's header button, a calendar's header button).
    /// The action is the same code either way.
    var chrome: CmsActionChrome = .block
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL

    @State private var running = false
    @State private var confirming = false
    @State private var result: String?
    @State private var failure: String?
    @State private var asking = false
    /// `menu`: open, where the button is on screen, the action being run
    /// (a row's, or nil for the button's own), and a placeholder's note.
    @State private var menuOpen = false
    @State private var anchor: CGRect = .zero
    #if os(iOS)
    @State private var anchorReader = CmsWindowFrameReader()
    #endif
    @State private var acting: [String: CmsJSON]?
    @State private var note: String?
    /// `form` on a sidebar part (a choice's row action, an add row, a header
    /// button): a record form, filled from the part's row (`_formRow`).
    @State private var rowForm: CmsRecordFormRequest?

    private var props: [String: CmsJSON] { runtime.resolvedProps(for: block) }
    /// The action's fields: a menu row's while it runs one, else the button's.
    private var act: [String: CmsJSON] { acting ?? props }
    private var actionType: String { act.string("actionType") ?? "mutation" }
    private var mutationSlug: String { act.string("mutationSlug") ?? "" }
    private var menu: CmsButtonMenu? { CmsButtonMenu(props["menu"]) }

    /// True where the page draws its floating button (CmsLevers).
    @Environment(\.cmsFloatingHost) private var floatingHost

    private var floating: Bool { props.string("placement") == "floating" }

    var body: some View {
        if chrome != .block {
            presented(chromeButton)
        } else if floating {
            // Floating: the page draws it in its overlay; its own place in the
            // page stays empty. The action is the same, input sheet included.
            if floatingHost && emptyMessage == nil && !autoHidden {
                presented(floatingButton)
            }
        } else if let empty = emptyMessage {
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
        // A menu without `primary` only opens and closes: no action of its own.
        if let menu, menu.primary == nil { return nil }
        if props.bool("placeholder") == true { return nil }
        guard acting == nil else { return nil }
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
        actionType == "mutation" ? runtime.mutationParams(mutationSlug, paramMap: act.object("paramMap")) : .none
    }

    private var waiting: Bool {
        if case .some(.none) = params { return true }
        return false
    }

    /// The mutation's declared inputs that the page does not supply.
    private var askedInputs: [CmsActionInputDef] {
        actionType == "mutation"
            ? CmsActionForm.askedInputs(runtime.mutationDefs[mutationSlug], paramMap: act.object("paramMap")) : []
    }

    private var webOnly: Bool { actionType == "exportSheet" || actionType == "computeLookup" }

    /// The button pressed: with a menu, it opens (or closes) the menu;
    /// otherwise it runs its action.
    private func trigger() {
        if props.bool("placeholder") == true {
            let label = props.string("label") ?? "This"
            Task { await showNote("\(label) is coming soon") }
        } else if menu != nil {
            setMenu(!menuOpen)
        } else {
            acting = nil
            perform()
        }
    }

    /// The full-screen cover the menu draws in appears and goes without the
    /// system's slide: the rows' own animation is the transition.
    private func setMenu(_ open: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            #if os(iOS)
            if open, let frame = anchorReader.frame { anchor = frame }
            #endif
            menuOpen = open
        }
    }

    /// A menu row chosen (nil: `primary`, the button's own action). A
    /// placeholder only says it is coming soon.
    private func runMenuItem(_ item: CmsButtonMenu.Item?) {
        if let item, item.placeholder {
            Task { await showNote(item.comingSoon) }
            return
        }
        acting = item?.action
        perform()
    }

    private func showNote(_ message: String) async {
        withAnimation { note = message }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation { if note == message { note = nil } }
    }

    private func perform() {
        if let spec = CmsRowFormSpec(act["form"]) {
            rowForm = CmsRecordFormRequest(spec: spec, row: act.object("_formRow") ?? [:])
            return
        }
        switch actionType {
        case "navigatePage":
            if let slug = act.string("targetPageSlug") { runtime.navigate(toPage: slug) }
        case "openUrl":
            if let url = act.string("url").flatMap(URL.init(string:)) { openURL(url) }
        case "switchGridView":
            if let grid = act.string("targetGridId"), let view = act.string("targetViewId") {
                runtime.gridViewRequest = CmsRuntime.GridViewRequest(gridId: grid, viewId: view)
            }
        case "clearSelection":
            if let slug = act.string("clearSelectionSlug") { runtime.setSelectedRows(slug, rows: []) }
        case "openSidebar":
            runtime.openSidebar(edge: act.string("edge"))
        case "mutation":
            let confirm = runtime.mutationDefs[mutationSlug]?.confirmMessage ?? ""
            // A mutation with a record form (`action.form`) always opens it.
            // As the site sets, a sheet or a page (CmsRecordFormPresenter); a plain input list stays a sheet.
            if runtime.mutationDefs[mutationSlug]?.opensRecordForm == true {
                rowForm = CmsRecordFormRequest(mutationSlug: mutationSlug, inputs: askedInputs, onSave: executeWithInputs)
            } else if !askedInputs.isEmpty { asking = true }
            else if confirm.isEmpty { execute() } else { confirming = true }
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
                await showResult(message)
            case .failed(let message):
                failure = message
            }
        }
    }

    /// Save in the input sheet: the form's values over the page's params,
    /// then the ordinary run. Returns the server's refusal for the sheet.
    private func executeWithInputs(_ formParams: [String: CmsJSON]) async -> String? {
        var merged: [String: CmsJSON] = [:]
        if case .some(.some(let p)) = params { merged = p }
        merged.merge(formParams) { _, form in form }
        // As `execute`: the button reads "Running…" meanwhile. The change of
        // title is also what makes the page measure the block again, so the
        // result line below it shows.
        running = true
        let outcome = await runtime.runMutation(mutationSlug, params: merged)
        running = false
        switch outcome {
        case .done(_, let message):
            // A record form's success shows at the page's foot, where a
            // floating button has no line of its own.
            if runtime.mutationDefs[mutationSlug]?.opensRecordForm == true { runtime.showNotice(message) }
            else { Task { await showResult(message) } }
            return nil
        case .failed(let message):
            return message
        }
    }

    private func showResult(_ message: String) async {
        withAnimation { result = message }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        withAnimation { if result == message { result = nil } }
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

    /// Round, 56 points, the accent fill, the icon (a nav icon key, else +)
    /// in paper; its label is its accessible name.
    private var floatingButton: some View {
        Button(action: trigger) {
            ZStack {
                if running {
                    ProgressView().tint(runtime.theme.color(role: .paper))
                } else {
                    Image(systemName: CmsNavIcon.symbol(for: props.string("icon")) ?? "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(runtime.theme.color(role: .paper))
                }
            }
            .frame(width: 56, height: 56)
            .background(Circle().fill(runtime.theme.accent))
            .shadow(color: runtime.theme.rgba(role: .text).withAlpha(0.2).color, radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(menu == nil && (running || waiting || webOnly))
        // The open menu draws its own copy of the button where this one is.
        .opacity(menuOpen ? 0 : 1)
        .accessibilityLabel(props.string("label") ?? "Add")
        .accessibilityHint(menu == nil ? "" : "Opens a menu")
        .cmsInspectorID("Cms.actionButton.floating")
        .overlay(alignment: .bottomTrailing) {
            if let note {
                noteView(note)
                    .fixedSize()
                    .offset(y: -68)
                    .transition(.opacity)
            }
        }
    }

    /// The chrome's button: an icon, a pill, plain words or a row.
    @ViewBuilder
    private var chromeButton: some View {
        let label = props.string("label") ?? ""
        let symbol = CmsButtonMenu.symbolName(props.object("media")?.string("symbol") ?? props.string("icon"))
        let image = props.object("media")?.string("image")
        let accent = runtime.theme.color(role: .primary)
        Group {
            switch chrome {
            case .block:
                EmptyView()
            case .icon:
                Button(action: trigger) {
                    // Its colour is the place's (a calendar's surface text, a row's tint).
                    Image(systemName: symbol ?? "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label.isEmpty ? "Action" : label)
            case .pill, .plain:
                let pill = chrome == .pill
                Button(action: trigger) {
                    HStack(spacing: 6) {
                        if !label.isEmpty {
                            Text(label).font(runtime.theme.font(size: 15, weight: .semibold))
                        }
                        CmsActionChromeIcon(symbol: symbol, image: image, size: 15)
                    }
                    .foregroundStyle(pill ? runtime.theme.color(role: .paper) : accent)
                    .padding(.horizontal, pill ? 14 : 0)
                    .padding(.vertical, pill ? 7 : 0)
                    .background { if pill { Capsule().fill(accent) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            case .row:
                Button(action: trigger) {
                    HStack(spacing: 12) {
                        CmsActionChromeIcon(symbol: symbol ?? "plus.circle.fill", image: image, size: 18)
                            .foregroundStyle(runtime.theme.accent)
                            .frame(width: 26)
                        Text(label)
                            .font(runtime.theme.font(size: 16, weight: .medium))
                            .foregroundStyle(runtime.theme.accent)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let note {
                noteView(note).fixedSize().offset(y: 40).transition(.opacity)
            }
        }
    }

    private func noteView(_ text: String) -> some View {
        Label(text, systemImage: "clock")
            .font(runtime.theme.font(size: 14, weight: .medium))
            .foregroundStyle(runtime.theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var content: some View {
        presented(inlineContent)
    }

    private var inlineContent: some View {
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
            .disabled(menu == nil && (running || waiting || webOnly))
            .accessibilityHint(menu == nil ? "" : "Opens a menu")
            .cmsInspectorID("Cms.actionButton.button")
            if let note {
                Label(note, systemImage: "clock")
                    .font(runtime.theme.font(size: 13, weight: .regular))
                    .foregroundColor(runtime.theme.textSecondary)
                    .transition(.opacity)
            }
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
    }

    /// The button's confirmation, input sheet and failure alert.
    private func presented<V: View>(_ view: V) -> some View {
        view
        #if os(iOS)
        // Where the button is, in window points, read as the menu opens
        // (setMenu): the menu draws in a full-screen cover. A SwiftUI `.global`
        // frame is its hosting view's, and the page's floating button measured
        // (128, 0) there for (330, 719) in the window on WAC Next's Records
        // (30 October 2026), so its menu opened at the top of the screen.
        .background(CmsWindowFrameProbe(reader: anchorReader))
        #endif
        .modifier(CmsButtonMenuPresenter(
            open: Binding(get: { menuOpen }, set: { setMenu($0) }),
            menu: menu, anchor: anchor, floating: floating,
            icon: CmsNavIcon.symbol(for: props.string("icon")) ?? "plus",
            primaryLabel: props.string("label") ?? "Add",
            run: runMenuItem))
        .modifier(CmsRecordFormPresenter(runtime: runtime, request: $rowForm))
        .alert("Confirm", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button(acting == nil ? props.string("label") ?? "Run" : "Run") { execute() }
        } message: {
            Text(runtime.mutationDefs[mutationSlug]?.confirmMessage ?? "")
        }
        .ripulSheet(isPresented: $asking) {
            let def = runtime.mutationDefs[mutationSlug]
            if let def, def.opensRecordForm {
                CmsRecordFormSheet(runtime: runtime, mutation: def, inputs: askedInputs, values: [:],
                                   onSave: executeWithInputs)
            } else {
            CmsActionInputSheet(
                runtime: runtime,
                title: def?.name.flatMap { $0.isEmpty ? nil : $0 } ?? props.string("label") ?? "Details",
                inputs: askedInputs,
                confirmMessage: def?.confirmMessage,
                confirmLabel: props.string("label") ?? "Run",
                onSave: executeWithInputs
            )
            }
        }
        .alert("Couldn't run that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func styled<B: View>(_ button: B) -> some View {
        // The site's own button corners (shape.buttonRadius; 999 or more is a pill), as the
        // web's; a site that sets none keeps the system's button shape.
        let shape = runtime.theme.buttonShape
        switch props.string("variant") ?? "contained" {
        case "outlined": button.buttonStyle(.bordered).buttonBorderShape(shape)
        case "text": button.buttonStyle(.borderless)
        default: button.buttonStyle(.borderedProminent).buttonBorderShape(shape)
        }
    }
}

/// Presents an open menu in a clear full-screen cover over everything, the
/// way WAC presents its own, so the backdrop covers the page and tab bar.
private struct CmsButtonMenuPresenter: ViewModifier {
    @Binding var open: Bool
    let menu: CmsButtonMenu?
    let anchor: CGRect
    let floating: Bool
    let icon: String
    let primaryLabel: String
    let run: (CmsButtonMenu.Item?) -> Void
    @EnvironmentObject private var runtime: CmsRuntime

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $open) {
            if let menu {
                CmsButtonMenuOverlay(menu: menu, anchor: anchor, floating: floating, icon: icon,
                                     primaryLabel: primaryLabel, run: run, close: { open = false })
                    .environmentObject(runtime)
                    .presentationBackground(.clear)
            }
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// A view's frame in its window's points, read when it is needed.
final class CmsWindowFrameReader {
    weak var view: UIView?

    var frame: CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

/// An empty UIKit view behind a SwiftUI view, for `CmsWindowFrameReader`.
private struct CmsWindowFrameProbe: UIViewRepresentable {
    let reader: CmsWindowFrameReader

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        reader.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { reader.view = view }
}
#endif

/// How an action is drawn when another block gives it (see
/// `CmsActionButtonBlockView.chrome`).
enum CmsActionChrome: Equatable {
    /// The action button block's own look.
    case block
    /// An icon button (a row's trailing action, a calendar's ☰).
    case icon
    /// A filled capsule, or plain words in the accent (a section's header button).
    case pill, plain
    /// A list row with a leading icon (a choice list's add row).
    case row
}

/// An action's icon: a symbol (a nav icon key or an SF Symbol name) or an image address.
struct CmsActionChromeIcon: View {
    let symbol: String?
    let image: String?
    let size: CGFloat

    var body: some View {
        if let image, let url = URL(string: image) {
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: size + 4, height: size + 4)
        } else if let symbol {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
        }
    }
}

extension CmsBlock {
    /// An action given inside another block (`rowAction`, `addRow`,
    /// `headerAction`, a calendar's `headerActions`): a block of the action
    /// button's type with those fields, drawn by the action button's code.
    static func action(id: String, props: [String: CmsJSON]) -> CmsBlock {
        CmsBlock(id: id, type: "actionButton", props: props)
    }
}
