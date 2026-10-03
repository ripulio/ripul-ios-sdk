import SwiftUI

/// Native twin of `stepProgress` (StepProgressBlock.tsx): where a visitor is
/// in a multi-page flow. Same props, defaults and current-step rule as the
/// web (`resolveCurrentStep`): the first step whose comma-separated
/// `whenValues` contains the source block's published output field, else the
/// step whose `pageSlug` is the page showing, else the first step.
///
/// The source block's output is read from `runtime.selectedRow(slug)` — the
/// native twin of `useSelectedRow`: control blocks publish their output row
/// under their own block slug in the runtime's selection store.
///
/// Presentation (Rule 0):
/// - `bar` is a native determinate `ProgressView` with a caption — iOS's own
///   progress idiom, tinted with the portal primary.
/// - `pills` is a wrapping row of capsules. iOS has no stepper-chip /
///   breadcrumb control (`UIPageControl` is anonymous dots with no labels,
///   and a segmented `Picker` implies free selection, which a flow's
///   progress is not), so a capsule row is the closest native-feeling
///   reading. It keeps the web's semantics: current = filled primary, done =
///   tinted (and tappable back to its page when `linkCompleted`), upcoming =
///   outlined; VoiceOver hears "Step n of m" and the selected trait.
struct CmsStepProgressBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    struct Step: Equatable {
        let label: String
        let pageSlug: String
        let whenValues: String
    }

    static let defaultSteps: [Step] = [
        Step(label: "Account", pageSlug: "", whenValues: ""),
        Step(label: "Payment", pageSlug: "", whenValues: ""),
        Step(label: "Setup", pageSlug: "", whenValues: ""),
    ]

    static func steps(from props: [String: CmsJSON]) -> [Step] {
        guard let raw = props["steps"] else { return defaultSteps }
        guard case .array(let rows) = raw else { return [] }
        return rows.compactMap { row in
            guard let obj = row.objectValue else { return nil }
            return Step(
                label: obj.string("label") ?? "",
                pageSlug: obj.string("pageSlug") ?? "",
                whenValues: obj.string("whenValues") ?? ""
            )
        }
    }

    /// Twin of the web's exported `resolveCurrentStep`.
    static func resolveCurrentStep(_ steps: [Step], pageSlug: String?, sourceValue: String?) -> Int {
        if let sourceValue, !sourceValue.isEmpty {
            let match = steps.firstIndex { step in
                step.whenValues
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .contains(sourceValue)
            }
            if let match { return match }
        }
        if let pageSlug, !pageSlug.isEmpty, let match = steps.firstIndex(where: { $0.pageSlug == pageSlug }) {
            return match
        }
        return 0
    }

    /// The source block's published output value, stringified like JS
    /// `String(raw)`; nil when absent / null / no source configured.
    private var sourceValue: String? {
        guard let slug = block.props.string("sourceBlockSlug"), !slug.isEmpty,
              let row = runtime.selectedRow(slug) else { return nil }
        let fieldProp = block.props.string("sourceField") ?? ""
        let field = fieldProp.isEmpty ? "step" : fieldProp
        guard let raw = row[field] else { return nil }
        switch raw {
        case .null: return nil
        case .object, .array: return nil
        default: return raw.displayString
        }
    }

    var body: some View {
        let steps = Self.steps(from: block.props)
        let current = Self.resolveCurrentStep(steps, pageSlug: runtime.currentPageSlug, sourceValue: sourceValue)
        if block.props.string("appearance") == "bar" {
            bar(steps: steps, current: current)
        } else {
            pills(steps: steps, current: current)
        }
    }

    // MARK: - Bar

    private func bar(steps: [Step], current: Int) -> some View {
        let label = current < steps.count ? steps[current].label : ""
        return VStack(alignment: .leading, spacing: 6) {
            Text("Step \(current + 1) of \(steps.count)\(label.isEmpty ? "" : " · \(label)")")
                .font(.caption.weight(.bold))
                .foregroundColor(runtime.theme.textSecondary)
            ProgressView(value: steps.isEmpty ? 0 : Double(current + 1), total: Double(max(steps.count, 1)))
                .progressViewStyle(.linear)
                .tint(runtime.theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pills

    private var alignment: Alignment {
        switch block.props.string("align") ?? "end" {
        case "center": return .center
        case "start": return .leading
        default: return .trailing
        }
    }

    private func pills(steps: [Step], current: Int) -> some View {
        let numbered = block.props.bool("numbered") ?? true
        let linkCompleted = block.props.bool("linkCompleted") ?? false
        let theme = runtime.theme
        return CmsStepFlowLayout(spacing: 8, alignment: alignment.horizontal) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let isCurrent = index == current
                let done = index < current
                let linkable = linkCompleted && done && !step.pageSlug.isEmpty && !runtime.isDesignMode
                Button {
                    guard linkable, step.pageSlug != runtime.currentPageSlug else { return }
                    runtime.navigate(toPage: step.pageSlug)
                } label: {
                    Text("\(numbered ? "\(index + 1). " : "")\(step.label)")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundColor(isCurrent ? theme.primaryContrast : done ? theme.primary : theme.textSecondary)
                        .background(Capsule().fill(isCurrent ? theme.primary : done ? theme.tint : theme.paper))
                        .overlay(Capsule().strokeBorder(isCurrent ? Color.clear : theme.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .allowsHitTesting(linkable)
                .accessibilityLabel("Step \(index + 1) of \(steps.count), \(step.label)\(done ? ", completed" : "")")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityRemoveTraits(linkable ? [] : .isButton)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// Wrapping row (CSS `flex-wrap: wrap` + `justify-content`) for the pills:
/// lays subviews left-to-right at their ideal size, breaking lines when the
/// proposed width runs out; each line is aligned start / center / end.
struct CmsStepFlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var result: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                result.append([])
                x = 0
            }
            result[result.count - 1].append((i, size))
            x += size.width + spacing
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, width: width)
        var height: CGFloat = 0
        var maxWidth: CGFloat = 0
        for (r, row) in rows.enumerated() {
            let rowWidth = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
            maxWidth = max(maxWidth, rowWidth)
            height += (row.map(\.size.height).max() ?? 0) + (r > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews, width: bounds.width) {
            let rowWidth = row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - rowWidth) / 2
            case .trailing: x = bounds.maxX - rowWidth
            default: x = bounds.minX
            }
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

/// Inspector schema — the scalar half of the web schema. The `steps`
/// repeater (with its page picker) stays on the web designer (the native
/// inspector has no repeater kind yet).
enum CmsStepProgressInspector {
    static let schema = CmsInspectorSchema(
        groups: [
            CmsPropertyGroup(id: "source", label: "Driven by a block", defaultExpanded: false),
            CmsPropertyGroup(id: "style", label: "Style", defaultExpanded: false),
        ],
        fields: [
            CmsPropertyField(key: "sourceBlockSlug", label: "Source block", kind: .string(placeholder: "checkout"),
                             group: "source",
                             helperText: "Slug of a block that publishes its current step (a Checkout publishes \"step\"). Optional.",
                             default: .string("")),
            CmsPropertyField(key: "sourceField", label: "Source field", kind: .string(), group: "source",
                             default: .string("step")),
            CmsPropertyField(key: "appearance", label: "Appearance", kind: .select(options: [
                CmsPropertyOption("pills", "Pills"),
                CmsPropertyOption("bar", "Bar"),
            ]), group: "style", default: .string("pills")),
            CmsPropertyField(key: "numbered", label: "Number the steps", kind: .boolean, group: "style",
                             default: .bool(true)),
            CmsPropertyField(key: "linkCompleted", label: "Completed steps link back", kind: .boolean,
                             group: "style", default: .bool(false)),
            CmsPropertyField(key: "align", label: "Align", kind: .select(options: [
                CmsPropertyOption("start", "Start"),
                CmsPropertyOption("center", "Center"),
                CmsPropertyOption("end", "End"),
            ]), group: "style", default: .string("end")),
        ]
    )
}
