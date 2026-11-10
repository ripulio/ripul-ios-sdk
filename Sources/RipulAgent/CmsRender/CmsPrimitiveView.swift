import SwiftUI

// MARK: - Primitives: drawing a resolved tree (docs/plans/cms-native-primitives.md, "Native first")
//
// Each kind is the platform's own layout: a stack is a VStack, a row an
// HStack, a grid a LazyVGrid, an overlay a ZStack, a scroll a horizontal
// ScrollView, text the system's text styles in the site's font (so it follows
// Dynamic Type). The tree is resolved by CmsPrimitives; nothing here decides
// what shows, only how.

/// A tree read from a site's definition, resolved against a row and the
/// runtime's queries, and drawn. Used by `card.layout` and the `layout` block.
struct CmsPrimitiveTree: View {
    let tree: CmsJSON
    let row: [String: CmsJSON]?
    /// A node's tap or long press: the action as written, and the row that node reads.
    /// A slot's column, as the host defines it (a cards rows item's `columns`); unset, the slot's own format.
    var column: ((String) -> CmsColumnPresentation)? = nil
    let perform: (CmsCardAction, [String: CmsJSON]?) -> Void
    @EnvironmentObject private var runtime: CmsRuntime

    var body: some View {
        let column = self.column
        let slot: (String, String?, [String: CmsJSON]) -> String = { name, format, row in
            guard let column else { return Self.slot(name, format, row) }
            if CmsPrimitives.rowValue(row, name) == nil, let builtIn = CmsLevers.builtIn(name, format: format) { return builtIn }
            return column(format.map { "\(name)|\($0)" } ?? name).text(row)
        }
        let result = CmsPrimitives.resolve(tree, row: row, rows: rows, slot: slot, format: Self.format)
        Group {
            if let root = result.root {
                CmsPrimitiveView(node: root, perform: perform)
            }
        }
        .task(id: CmsPrimitives.querySlugs(tree)) {
            for slug in CmsPrimitives.querySlugs(tree) { runtime.ensureLoaded(slug) }
        }
    }

    private func rows(_ slug: String) -> CmsPrimitiveRows {
        switch runtime.state(for: slug) {
        case .ok(let result): return .ready(result.rows)
        case .error: return .error
        default: return .loading
        }
    }

    /// A slot's words: the column in its format, or the built-in `{today}` and
    /// `{timeOfDay}` when the row has no column of that name (the list rows' rule).
    static func slot(_ column: String, _ format: String?, _ row: [String: CmsJSON]) -> String {
        if CmsPrimitives.rowValue(row, column) == nil, let builtIn = CmsLevers.builtIn(column, format: format) { return builtIn }
        var json: [String: CmsJSON] = ["valueFrom": .string(column)]
        if let format { json["format"] = .string(format) }
        return CmsColumnPresentation(key: column, json: json).text(row)
    }

    /// An expression's value in a column format.
    static func format(_ value: CmsFormValue, _ format: String) -> String {
        let json: CmsJSON
        switch value {
        case .number(let n): json = .number(n)
        case .text(let t): json = .string(t)
        case .blank: return ""
        }
        return CmsColumnPresentation(key: "value", json: ["valueFrom": .string("value"), "format": .string(format)]).text(["value": json])
    }
}

/// One resolved node and those inside it.
struct CmsPrimitiveView: View {
    let node: CmsPrimitive
    let perform: (CmsCardAction, [String: CmsJSON]?) -> Void
    /// A grid's cell: it takes the row's full height, as a CSS grid's items do.
    var stretch = false
    @EnvironmentObject private var runtime: CmsRuntime
    @Environment(\.dynamicTypeSize) private var typeSize

    private var theme: CmsPortalTheme { runtime.theme }

    var body: some View {
        let tap = node.tap.flatMap(CmsCardAction.init).flatMap(available)
        let longPress = node.longPress.flatMap(CmsCardAction.init).flatMap(available)
        let drawn = framed(content)
        Group {
            if let tap {
                Button { perform(tap, node.row) } label: { drawn.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in if let longPress { perform(longPress, node.row) } })
            } else if let longPress {
                drawn.onLongPressGesture { perform(longPress, node.row) }
                    .accessibilityAddTraits(.isButton)
            } else {
                drawn
            }
        }
        .modifier(Accessibility(node: node))
    }

    /// An `open: { host }` this app doesn't handle is left out, as on cards.
    private func available(_ action: CmsCardAction) -> CmsCardAction? {
        action.available(hostActions: Set(runtime.hostActions.keys)) ? action : nil
    }

    // MARK: The box every node has

    @ViewBuilder
    private func framed<V: View>(_ inner: V) -> some View {
        let padded = inner.padding(node.padding.map { EdgeInsets(top: $0.top, leading: $0.leading, bottom: $0.bottom, trailing: $0.trailing) } ?? EdgeInsets())
        let sized = padded
            .frame(width: points(node.width), height: points(node.height))
            .frame(maxWidth: node.width == .fill ? .infinity : nil,
                   maxHeight: (node.height == .fill && node.kind != "spacer") || stretch ? .infinity : nil,
                   alignment: boxAlignment)
        let shape = boxShape
        sized
            .background { if let role = node.background { shape.fill(theme.color(role: role)) } }
            .overlay { if let role = node.border { shape.stroke(theme.color(role: role), lineWidth: 1) } }
            .modifier(Clip(shape: node.radius != nil && (node.background != nil || node.kind == "overlay" || node.kind == "image") ? shape : nil))
    }

    /// The box's outline: a circle or capsule shape's own, an image's circle, else its radius.
    private var boxShape: AnyShape {
        if (node.kind == "shape" || node.kind == "image") && node.shape == "circle" { return AnyShape(Circle()) }
        if node.kind == "shape" && node.shape == "capsule" { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0), style: .continuous))
    }

    private func points(_ size: CmsPrimitive.Size) -> CGFloat? {
        if case .points(let n) = size { return CGFloat(n) }
        return nil
    }

    /// Where the content sits in a box wider than it: text by its own alignment, a stack by its.
    private var boxAlignment: Alignment {
        switch node.kind {
        case "text": return node.align == "center" ? .center : node.align == "trailing" ? .trailing : .leading
        case "stack": return node.align == "center" ? .top : node.align == "trailing" ? .topTrailing : .topLeading
        case "overlay", "image", "shape", "loading": return .center
        default: return .leading
        }
    }

    // MARK: Each kind

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case "stack":
            VStack(alignment: horizontal(node.align), spacing: CGFloat(node.gap ?? 0)) { children }
        case "row":
            if node.stackAtLargeText && typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: CGFloat(node.gap ?? 0)) { children }
            } else {
                // The web's flex row: each child that fits its content takes its ideal
                // width first, and a spacer (or a `fill` child) has what is left. A
                // SwiftUI HStack otherwise offers equal shares, so "£32.00" broke
                // beside a spacer that still had room. Text wraps only once the
                // spacers are down to their `min`.
                HStack(alignment: vertical(node.align), spacing: CGFloat(node.gap ?? 0)) {
                    ForEach(node.children ?? []) { child in
                        CmsPrimitiveView(node: child, perform: perform)
                            .layoutPriority(Self.rowPriority(child))
                    }
                }
            }
        case "grid":
            let gap = CGFloat(node.gap ?? 0)
            let columns = node.minWidth.map { [GridItem(.adaptive(minimum: CGFloat($0)), spacing: gap, alignment: .topLeading)] }
                ?? Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .topLeading), count: node.columns ?? 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(node.children ?? []) { CmsPrimitiveView(node: $0, perform: perform, stretch: true) }
            }
        case "overlay":
            overlay
        case "scroll":
            scroll
        case "spacer":
            Spacer(minLength: CGFloat(node.min ?? 0))
        case "text":
            text
        case "image":
            image
        case "icon":
            icon
        case "shape":
            shape
        case "badge":
            badge
        case "divider":
            Divider().overlay(theme.color(role: node.color ?? .divider))
        case "loading":
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
        default:
            EmptyView()
        }
    }

    /// The children without a `place` size the overlay, layered at its `align`;
    /// each placed child sits over them at its anchor, so a badge never grows the box.
    @ViewBuilder
    private var overlay: some View {
        let all = node.children ?? []
        let base = all.filter { $0.place == nil }
        let placed = all.filter { $0.place != nil }
        let layers = ZStack(alignment: alignment(node.align) ?? .center) {
            ForEach(base) { CmsPrimitiveView(node: $0, perform: perform) }
        }
        if base.isEmpty {
            // Nothing sizes it (a picture left out): each placed child keeps its side across the box's width.
            ZStack(alignment: .top) {
                ForEach(placed) { child in
                    CmsPrimitiveView(node: child, perform: perform)
                        .frame(maxWidth: .infinity, alignment: alignment(child.place) ?? .center)
                }
            }
        } else {
            placed.reduce(AnyView(layers)) { view, child in
                AnyView(view.overlay(alignment: alignment(child.place) ?? .center) {
                    CmsPrimitiveView(node: child, perform: perform)
                })
            }
        }
    }

    private var children: some View {
        ForEach(node.children ?? []) { CmsPrimitiveView(node: $0, perform: perform) }
    }

    @ViewBuilder
    private var scroll: some View {
        let stack = LazyHStack(alignment: .top, spacing: CGFloat(node.gap ?? 0)) { children }.scrollTargetLayout()
        if node.paging {
            ScrollView(.horizontal, showsIndicators: false) { stack }.scrollTargetBehavior(.paging)
        } else {
            ScrollView(.horizontal, showsIndicators: false) { stack }.scrollTargetBehavior(.viewAligned)
        }
    }

    private var text: some View {
        let style = node.style ?? "body"
        let weight: Font.Weight = switch node.weight {
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "regular": .regular
        default: style == "headline" ? .semibold : .regular
        }
        return Text(node.text ?? "")
            .modifier(CmsScaledFont(theme: theme, size: CGFloat(CmsPrimitives.textStyles[style] ?? 17), weight: weight,
                                    relativeTo: Self.textStyle(style)))
            .foregroundStyle(theme.color(role: node.color ?? .text))
            .lineLimit(node.lines)
            .multilineTextAlignment(node.align == "center" ? .center : node.align == "trailing" ? .trailing : .leading)
    }

    @ViewBuilder
    private var image: some View {
        let candidates = imageCandidates
        let shape: AnyShape = node.shape == "circle" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0), style: .continuous))
        if node.template {
            CmsColumnPicture(candidates: candidates, size: points(node.width) ?? points(node.height) ?? 24, cornerRadius: 0,
                             template: theme.color(role: node.color ?? .text))
        } else {
            let picture = CmsChainImage(candidates: candidates, fit: node.fit == "fit" ? "contain" : "cover")
            if let aspect = node.aspect {
                picture.aspectRatio(CGFloat(aspect), contentMode: .fit).clipShape(shape)
            } else {
                picture.clipShape(shape)
            }
        }
    }

    private var imageCandidates: [CmsCalendarDecorations.ImageCandidate] {
        var out: [CmsCalendarDecorations.ImageCandidate] = []
        if let row = node.row, let chain = node.chain {
            out += CmsCalendarDecorations.imageCandidates(row, CmsCalendarDecorations.imageChain(.array(chain)))
        }
        if let src = node.src, !out.contains(.url(src)) { out.append(.url(src)) }
        return out
    }

    @ViewBuilder
    private var icon: some View {
        // An SF Symbol on iPhone; a nav icon key maps to its symbol. Material names are the web's and Android's.
        if let symbol = node.sf ?? node.name.map({ CmsNavIcon.symbol(for: $0) ?? $0 }) {
            Image(systemName: symbol)
                .font(.system(size: CGFloat(node.size ?? 20)))
                .foregroundStyle(theme.color(role: node.color ?? .text))
        }
    }

    @ViewBuilder
    private var shape: some View {
        let colour = theme.color(role: node.fill ?? .surfaceMuted)
        switch node.shape {
        case "capsule": Capsule().fill(colour)
        case "circle": Circle().fill(colour)
        default: RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0), style: .continuous).fill(colour)
        }
    }

    private var badge: some View {
        let role = theme.color(role: node.color ?? .primary)
        let filled = node.look == "filled"
        return Text(node.text ?? "")
            .modifier(CmsScaledFont(theme: theme, size: 12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(filled ? Color.white : role) // theme-exempt: white on a filled badge, the web's rule
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? role : role.opacity(0.15)))
    }

    // MARK: Mapping words to SwiftUI

    /// A row child's claim on the width: 1 for one sized by its content or in
    /// points, 0 for a spacer or a `fill` child (the web's `flex: 1`).
    static func rowPriority(_ child: CmsPrimitive) -> Double {
        child.kind == "spacer" || child.width == .fill ? 0 : 1
    }

    static func textStyle(_ name: String) -> Font.TextStyle {
        switch name {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "callout": .callout
        case "subheadline": .subheadline
        case "footnote": .footnote
        case "caption": .caption
        case "caption2": .caption2
        default: .body
        }
    }

    private func horizontal(_ align: String?) -> HorizontalAlignment {
        align == "center" ? .center : align == "trailing" ? .trailing : .leading
    }

    private func vertical(_ align: String?) -> VerticalAlignment {
        switch align {
        case "top": .top
        case "bottom": .bottom
        case "baseline": .firstTextBaseline
        default: .center
        }
    }

    private func alignment(_ place: String?) -> Alignment? {
        switch place {
        case "topLeading": .topLeading
        case "top": .top
        case "topTrailing": .topTrailing
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        case "bottomLeading": .bottomLeading
        case "bottom": .bottom
        case "bottomTrailing": .bottomTrailing
        default: nil
        }
    }

    /// A rounded box with a fill, an overlay or a picture keeps its content inside its corners.
    private struct Clip: ViewModifier {
        let shape: AnyShape?

        func body(content: Content) -> some View {
            if let shape { content.clipShape(shape) } else { content }
        }
    }

    /// `label`, `hidden` and `testId`. A node with a tap and no label reads its text children.
    private struct Accessibility: ViewModifier {
        let node: CmsPrimitive

        func body(content: Content) -> some View {
            let labelled = Group {
                // A picture says nothing unless it is labelled (the agreed seam).
                if node.hidden || (node.kind == "image" && node.label == nil) {
                    content.accessibilityHidden(true)
                } else if let label = node.label {
                    content.accessibilityElement(children: .ignore).accessibilityLabel(label)
                } else if node.tap != nil {
                    content.accessibilityElement(children: .combine)
                } else {
                    content
                }
            }
            if let testId = node.testId {
                labelled.accessibilityIdentifier(testId)
            } else {
                labelled
            }
        }
    }
}
