import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The `cards` block, natively (docs/plans/cms-cards.md §9): cards the site
/// wrote and cards per row of a query or view, as a stack in the page, a
/// paged carousel with the system's page dots, or only the first that shows.
/// Rules are in CmsCards.swift; the look is the theme's card style
/// (CmsCardStyle.swift). A card's lines, chip and pictures are the list
/// row's pieces.
struct CmsCardsBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL

    /// Cards closed on this device (and this session's closes, before they save).
    @State private var closed: Set<String> = []
    /// A card's `open: { form }`: the record form it opened.
    @State private var recordForm: CmsRecordFormRequest?
    /// Cards hidden while their closing mutation runs.
    @State private var closing: Set<String> = []
    /// A variant shown on request (`show`), with the row it was asked on.
    @State private var requested: [String: (variant: String, row: [String: CmsJSON]?)] = [:]
    /// A variant shown while a button's mutation runs (`pending`).
    @State private var running: [String: String] = [:]
    @State private var confirm: Confirm?
    @State private var asking: Ask?
    @State private var failure: String?

    private var props: CmsCardsProps { CmsCardsProps(runtime.resolvedProps(for: block)) }
    @Environment(\.cmsBleed) private var bleed
    @Environment(\.cmsOverlap) private var overlap
    /// Closing is remembered per block, by its slug as the web keys it.
    private var blockKey: String { block.slug ?? block.id }

    private var style: CmsResolvedCardStyle {
        CmsResolvedCardStyle(config: runtime.themeConfig, block: props.cardStyle, theme: runtime.theme)
    }

    var body: some View {
        let props = self.props
        let style = self.style
        let places = arrangedPlaces(props)
        Group {
            switch props.display {
            case "carousel":
                let cards = places.flatMap(\.cards)
                if !cards.isEmpty {
                    CmsPagedCarousel(ids: cards.map(\.id), options: props.carousel, style: style) { id in
                        if let card = cards.first(where: { $0.id == id }) { cardView(card, style: style) }
                    }
                }
            case "first":
                // The first place that isn't an error; a query still loading
                // holds it as a loading card.
                if let first = places.first {
                    if case .loading = first {
                        CmsCardsLoadingCard(style: style)
                    } else if case .card = first, !swipeSet(for: first).isEmpty {
                        GlassSwipeList([first], id: \.id, swipe: { swipeSet(for: $0) }) { place in
                            placeView(place, props: props, style: style)
                        }
                    } else if let card = first.cards.first {
                        cardView(card, style: style)
                    }
                }
            default:
                let shown = places.filter { if case .loading = $0 { return false }; return true }
                if shown.contains(where: { !swipeSet(for: $0).isEmpty }) {
                    // Cards that swipe: the stack is a real List (the shared
                    // GlassSwipeList) with each card a row, for the system's
                    // swipe actions; it is as tall as its cards and doesn't scroll.
                    GlassSwipeList(shown, id: \.id, spacing: style.number("surface", "gap"),
                                   swipe: { swipeSet(for: $0) }) { place in
                        placeView(place, props: props, style: style)
                            .environment(\.cmsBleed, place.id == shown.first?.id ? bleed : bleed.map { _ in .sideways })
                            .environment(\.cmsOverlap, place.id == shown.last?.id ? overlap : 0)
                    }
                } else {
                VStack(alignment: .leading, spacing: style.number("surface", "gap")) {
                    ForEach(shown) { place in
                        placeView(place, props: props, style: style)
                            // A bleeding block: only its first card runs under the status bar.
                            .environment(\.cmsBleed, place.id == shown.first?.id ? bleed : bleed.map { _ in .sideways })
                            // `overlap` grows only the last card's surface.
                            .environment(\.cmsOverlap, place.id == shown.last?.id ? overlap : 0)
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
                .animation(.snappy, value: places.map(\.id))
                }
            }
        }
        .onAppear { loadQueries(props) }
        .onAppear { closed = CmsCardsClosedStore.closed(cmsId: runtime.cmsId, blockId: blockKey) }
        .alert("Confirm", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button(confirm?.label ?? "Run") { if let c = confirm { execute(c.slug, params: c.params, card: c.card, pending: c.pending) } }
        } message: {
            Text(confirm?.message ?? "")
        }
        .ripulSheet(isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            if let ask = asking {
                let def = runtime.mutationDefs[ask.slug]
                let save: ([String: CmsJSON]) async -> String? = { form in
                    var merged = ask.params
                    merged.merge(form) { _, new in new }
                    return await run(ask.slug, params: merged, card: ask.card, pending: ask.pending)
                }
                if let def, def.opensRecordForm {
                    CmsRecordFormSheet(runtime: runtime, mutation: def, inputs: ask.inputs, values: ask.params, onSave: save)
                } else {
                    CmsActionInputSheet(
                        runtime: runtime,
                        title: def?.name.flatMap { $0.isEmpty ? nil : $0 } ?? ask.label,
                        inputs: ask.inputs,
                        confirmMessage: def?.confirmMessage,
                        confirmLabel: ask.label,
                        onSave: save
                    )
                }
            }
        }
        .alert("Couldn't run that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .modifier(CmsRecordFormPresenter(runtime: runtime, request: $recordForm))
        .cmsInspectorID("Cms.cards")
    }

    // MARK: Places

    private func loadQueries(_ props: CmsCardsProps) {
        var slugs: Set<String> = []
        for item in props.items {
            switch item {
            case .card(let card):
                if let q = card.query { slugs.insert(q) }
                for c in [card.when] + card.variants.map(\.when) { if case .rows(let q, _)? = c { slugs.insert(q) } }
            case .rows(let rows):
                slugs.insert(rows.query)
            }
        }
        for slug in slugs { runtime.ensureLoaded(slug) }
    }

    private func rows(_ slug: String) -> [[String: CmsJSON]]? {
        if case .ok(let result) = runtime.state(for: slug) { return result.rows }
        return nil
    }

    private func rowCount(_ slug: String) -> Int? {
        runtime.ensureLoaded(slug)
        return rows(slug)?.count
    }

    private func isLoading(_ slug: String) -> Bool {
        switch runtime.state(for: slug) {
        case .idle, .loading, .waiting: return true
        default: return false
        }
    }

    private func queryFailure(_ slug: String) -> String? {
        if case .error(let message) = runtime.state(for: slug) { return message }
        return nil
    }

    /// A written card's `when` (or a variant's) reads its query's row, still loading.
    private func waitsOnQuery(_ card: CmsCardInstance) -> Bool {
        card.queryWaiting && ([card.card.when] + card.card.variants.map(\.when)).contains { $0?.column != nil }
    }

    private func arrangedPlaces(_ props: CmsCardsProps) -> [CmsCardsPlace] {
        CmsCards.places(items: props.items, rows: rows, loading: isLoading, failure: queryFailure,
                        visible: isVisible) { spec, value, groupRows in
            guard let header = spec.group?.header else { return nil }
            return CmsCards.headerText(header, groupColumn: spec.group?.by, value: value,
                                       rows: groupRows, columns: spec.columns ?? [])
                .map { runtime.resolveTemplate($0) }
        }
    }

    /// Its `when` holds (or waits on a source still coming), today is in its
    /// dates, and it hasn't been closed.
    private func isVisible(_ card: CmsCardInstance) -> Bool {
        if closed.contains(card.closeKey) || closing.contains(card.id) { return false }
        guard card.card.inWindow() else { return false }
        guard let when = card.card.when else { return true }
        if waitsOnSource(card, columns: [when.column].compactMap { $0 }) { return true }
        // Its query still loading: it holds its place, as a placeholder card.
        if card.queryWaiting, when.column != nil { return true }
        return when.holds(row: card.row, rowCount: rowCount)
    }

    @ViewBuilder
    private func placeView(_ place: CmsCardsPlace, props: CmsCardsProps, style: CmsResolvedCardStyle) -> some View {
        switch place {
        case .card(let card):
            cardView(card, style: style)
        case .loading:
            CmsCardsLoadingCard(style: style)
        case .group(_, let header, let display, let cards):
            VStack(alignment: .leading, spacing: 8) {
                if let header {
                    Text(header)
                        .font(style.theme.font(size: 13, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(style.color("eyebrow", "color"))
                        .accessibilityAddTraits(.isHeader)
                }
                switch display {
                case "first":
                    if let first = cards.first { cardView(first, style: style) }
                case "stack":
                    VStack(spacing: style.number("surface", "gap")) {
                        ForEach(cards) { cardView($0, style: style) }
                    }
                default:
                    if cards.count == 1 {
                        cardView(cards[0], style: style)
                    } else {
                        CmsPagedCarousel(ids: cards.map(\.id), options: props.carousel, style: style) { id in
                            if let card = cards.first(where: { $0.id == id }) { cardView(card, style: style) }
                        }
                    }
                }
            }
        }
    }

    // MARK: A card

    private func cardView(_ instance: CmsCardInstance, style: CmsResolvedCardStyle) -> some View {
        let wanted = requested[instance.id].flatMap { $0.row == instance.row ? $0.variant : nil }
        let resolved = instance.card.resolvedParts(row: instance.row, requested: running[instance.id] ?? wanted,
                                                   rowCount: rowCount)
        let view = viewDef(instance)
        // Failed: only the sources the drawn parts read.
        let aliases = CmsCards.aliases(of: resolved.parts, card: instance.card, view: view, conditions: false)
        let statuses = aliases.map { status(instance, alias: $0) }
        // Waiting: a condition reads a source still coming, or a `rows` condition's query still loads.
        let rowsLoading = ([instance.card.when] + instance.card.variants.map(\.when)).contains { c in
            if case .rows(let q, _)? = c { return isLoading(q) }
            return false
        }
        let waitingCard = rowsLoading || waitsOnQuery(instance)
            || waitsOnSource(instance, columns: instance.card.conditionColumns)
        let failed = instance.queryFailed
            ?? statuses.compactMap { s -> String? in if case .failed(let m) = s { return m }; return nil }.first
        return CmsCardFace(
            instance: instance,
            parts: resolved.parts,
            style: style,
            column: { presentation($0, instance: instance) },
            pendingAlias: { alias in
                switch status(instance, alias: alias) {
                case .pending, .later: return true
                default: return false
                }
            },
            placeholder: waitingCard,
            queryWaiting: instance.queryWaiting,
            failed: failed,
            retry: {
                if instance.queryFailed != nil, let source = instance.source {
                    runtime.invalidate(source)
                } else if let source = instance.source, let key = instance.rowKey {
                    runtime.retryViewRow(source, key: key)
                }
            },
            perform: { action in
                // A button's own label names its confirm, not "Run".
                let label = (resolved.parts.buttons ?? []).first { $0.action == action }?.label ?? "OK"
                perform(action, card: instance, parts: resolved.parts, label: label)
            },
            closeCard: { close(instance, parts: resolved.parts) },
            performOnRow: { action, row in
                // A node in the card's layout acts on the row it reads (a repeated row's own).
                var acting = instance
                acting.row = row ?? instance.row
                perform(action, card: acting, parts: resolved.parts, label: "OK")
            }
        )
        .onAppear { askForLaterRows(instance) }
    }

    // MARK: Swipe actions

    /// A card's swipe actions (its parts' `swipe`, against its row); none for groups and loading places.
    private func swipeSet(for place: CmsCardsPlace) -> GlassSwipeSet {
        guard case .card(let instance) = place else { return .none }
        let wanted = requested[instance.id].flatMap { $0.row == instance.row ? $0.variant : nil }
        let parts = instance.card.resolvedParts(row: instance.row, requested: running[instance.id] ?? wanted,
                                                rowCount: rowCount).parts
        guard let config = parts.swipe else { return .none }
        return CmsSwipe.glassSet(CmsSwipe.resolve(config, row: instance.row ?? [:]), theme: runtime.theme,
                                 key: instance.id) { action in
            performSwipe(action, card: instance, parts: parts)
        }
    }

    /// A swipe action: its own confirm text first, else the action as a button runs it.
    private func performSwipe(_ swipe: CmsSwipe.Action, card: CmsCardInstance, parts: CmsCardParts) {
        if case .run(let slug, let inputs, _) = swipe.action, let message = swipe.confirm,
           CmsActionForm.askedInputs(runtime.mutationDefs[slug], paramMap: inputs).isEmpty {
            confirm = Confirm(slug: slug, params: CmsCards.inputs(inputs, row: card.row), card: card,
                              pending: nil, label: swipe.label, message: message)
            return
        }
        perform(swipe.action, card: card, parts: parts, label: swipe.label)
    }

    private func viewDef(_ instance: CmsCardInstance) -> CmsViewDef? {
        instance.source.flatMap { runtime.viewDefs[$0] }
    }

    private func status(_ instance: CmsCardInstance, alias: String) -> CmsViewSourceStatus {
        guard let source = instance.source, let row = instance.row else { return .ready }
        return runtime.viewSourceStatus(source, row: row, alias: alias)
    }

    /// Whether any of these columns reads a view source that is still coming.
    private func waitsOnSource(_ instance: CmsCardInstance, columns: [String]) -> Bool {
        guard let view = viewDef(instance) else { return false }
        let known = Set((view.sources ?? []).map(\.alias))
        return columns.contains { column in
            guard let dot = column.firstIndex(of: ".") else { return false }
            let alias = String(column[..<dot])
            guard known.contains(alias) else { return false }
            switch status(instance, alias: alias) {
            case .pending, .later: return true
            default: return false
            }
        }
    }

    /// Rows past the first 20 come back `later`: ask for the next 20 as a card comes into view.
    private func askForLaterRows(_ instance: CmsCardInstance) {
        guard let source = instance.source, let key = instance.rowKey,
              let result = runtime.viewResults[source], result.status[key]?.values.contains(.later) == true else { return }
        let later = result.laterKeys
        guard let start = later.firstIndex(of: key) else { return }
        runtime.requestViewRows(source, keys: Array(later[start..<min(start + 20, later.count)]))
    }

    /// A slot's column: the rows item's column definition (format, rules,
    /// chip, picture), with a slot's own format (`{pay|£#,##0.00}`) over it.
    private func presentation(_ slot: String, instance: CmsCardInstance) -> CmsColumnPresentation {
        let (column, format) = CmsCards.splitSlot(slot)
        var json = (instance.columns ?? []).compactMap(\.objectValue).first {
            $0.string("key") == column || $0.string("valueFrom") == column
        } ?? [:]
        if json["valueFrom"] == nil { json["valueFrom"] = .string(column) }
        if let format { json["format"] = .string(format) }
        return CmsColumnPresentation(key: column, json: json)
    }

    // MARK: Actions

    private struct Confirm {
        var slug: String
        var params: [String: CmsJSON]
        var card: CmsCardInstance
        var pending: String?
        var label: String
        var message: String
    }

    private struct Ask {
        var slug: String
        var params: [String: CmsJSON]
        var inputs: [CmsActionInputDef]
        var card: CmsCardInstance
        var pending: String?
        var label: String
    }

    private func perform(_ action: CmsCardAction, card: CmsCardInstance, parts: CmsCardParts, label: String = "Run") {
        switch action {
        case .openPage(let page, let params):
            // No page parameters: the card's row, with the filled params over
            // it, becomes its query's selection (as a grid's drill), then the page opens.
            if let source = card.source, var row = card.row {
                for (name, raw) in params {
                    let typed = CmsCards.inputs([name: raw], row: card.row)[name]?.objectValue?["value"] ?? raw
                    row[name] = typed
                }
                runtime.setSelectedRows(source, rows: [row])
            }
            runtime.navigate(toPage: page)
        case .openURL(let address):
            let filled = card.row.flatMap { CmsListRowLayout.fill(address, row: $0) { presentation($0, instance: card) } } ?? address
            if let url = URL(string: filled) { openURL(url) }
        case .openTab(let tab):
            runtime.navigate(toPage: tab)
        case .openSidebar(let edge):
            runtime.openSidebar(edge: edge)
        case .openForm(let spec):
            recordForm = CmsRecordFormRequest(spec: spec, row: card.row ?? [:])
        case .openHost(let name):
            runtime.hostActions[name]?()
        case .openWeb(let address, let title):
            CmsWebPage.open(address, title: title, row: card.row, runtime: runtime)
        case .show(let variant):
            requested[card.id] = (variant, card.row)
        case .close:
            close(card, parts: parts)
        case .run(let slug, let inputs, let pending):
            requested[card.id] = nil
            let params = CmsCards.inputs(inputs, row: card.row)
            let def = runtime.mutationDefs[slug]
            let asked = CmsActionForm.askedInputs(def, paramMap: inputs)
            if !asked.isEmpty {
                asking = Ask(slug: slug, params: params, inputs: asked, card: card, pending: pending, label: label)
            } else if let message = def?.confirmMessage, !message.isEmpty {
                confirm = Confirm(slug: slug, params: params, card: card, pending: pending, label: label, message: message)
            } else {
                execute(slug, params: params, card: card, pending: pending)
            }
        }
    }

    private func execute(_ slug: String, params: [String: CmsJSON], card: CmsCardInstance, pending: String?) {
        Task {
            if let message = await run(slug, params: params, card: card, pending: pending) { failure = message }
        }
    }

    /// Runs a mutation, showing `pending` on the card meanwhile; the refetched
    /// row's own state takes over after. Returns a failure's message.
    private func run(_ slug: String, params: [String: CmsJSON], card: CmsCardInstance, pending: String?) async -> String? {
        if let pending { withAnimation { running[card.id] = pending } }
        let outcome = await runtime.runMutation(slug, params: params)
        withAnimation { running[card.id] = nil }
        if case .failed(let message) = outcome { return message }
        return nil
    }

    private func close(_ card: CmsCardInstance, parts: CmsCardParts) {
        switch parts.close {
        case .run(let slug, let inputs)?:
            withAnimation { _ = closing.insert(card.id) }
            Task {
                let outcome = await runtime.runMutation(slug, params: CmsCards.inputs(inputs, row: card.row))
                // The refetched rows decide what shows; a failure brings the card back.
                withAnimation { _ = closing.remove(card.id) }
                if case .failed(let message) = outcome { failure = message }
            }
        default:
            CmsCardsClosedStore.close(card.closeKey, cmsId: runtime.cmsId, blockId: blockKey)
            withAnimation { _ = closed.insert(card.closeKey) }
        }
    }
}

// MARK: - A card's drawing

struct CmsCardFace: View {
    let instance: CmsCardInstance
    let parts: CmsCardParts
    let style: CmsResolvedCardStyle
    let column: (String) -> CmsColumnPresentation
    let pendingAlias: (String) -> Bool
    /// The card's `when` waits on a source still coming: drawn as a placeholder.
    let placeholder: Bool
    /// A written card's `query` still loading: its slots draw as placeholders.
    var queryWaiting = false
    let failed: String?
    let retry: () -> Void
    let perform: (CmsCardAction) -> Void
    let closeCard: () -> Void
    /// A `layout` node's tap: the action, and the row that node reads.
    var performOnRow: ((CmsCardAction, [String: CmsJSON]?) -> Void)? = nil
    @EnvironmentObject private var runtime: CmsRuntime
    @Environment(\.cmsBleed) private var bleed
    @Environment(\.cmsOverlap) private var cardOverlap

    /// The host actions this app handles; a part naming another is left out.
    private var hostActions: Set<String> { Set(runtime.hostActions.keys) }

    private var tap: CmsCardAction? { parts.tap.flatMap { $0.available(hostActions: hostActions) ? $0 : nil } }
    private var accessory: CmsCardAccessory? {
        parts.accessory.flatMap { $0.action.available(hostActions: hostActions) ? $0 : nil }
    }
    private var buttons: [CmsCardButton] { (parts.buttons ?? []).filter { $0.action.available(hostActions: hostActions) } }

    /// `text.align: center`: the text and the buttons centred.
    private var centred: Bool { style.string("text", "align") == "center" }

    private var tone: CmsResolvedCardStyle.Tone? {
        guard let raw = parts.tone else { return nil }
        let name = instance.row.flatMap { CmsListRowLayout.fill(raw, row: $0, column: column) } ?? raw
        return style.tone(name)
    }

    var body: some View {
        let tone = self.tone
        let radius = style.number("surface", "cornerRadius")
        let shape = bleed.map { AnyShape($0.shape(radius: radius)) }
            ?? AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // `layout` replaces the card's interior parts (media, eyebrow, title,
        // body, value, figures, lines and chip); the surface, tap, buttons,
        // accessory, close and swipe stay the card's.
        let top = parts.layout == nil && parts.mediaPlacement == "top" ? parts.media : nil
        let content = VStack(alignment: .leading, spacing: 0) {
            // A picture across the top bleeds to the card's edges.
            if let top { mediaView(top, top: true, tone: tone) }
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: style.number("media", "size") > 0 && style.string("media", "shape") == "none" ? .center : .top,
                   spacing: style.number("media", "gap")) {
                if let layout = parts.layout {
                    CmsPrimitiveTree(tree: layout, row: instance.row, column: column) { action, row in
                        if let performOnRow { performOnRow(action, row) } else { perform(action) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if parts.mediaPlacement != "top", let media = parts.media {
                        mediaView(media, top: false, tone: tone)
                    }
                    VStack(alignment: centred ? .center : .leading, spacing: style.number("text", "gap")) {
                        textParts(tone: tone)
                    }
                    .multilineTextAlignment(centred ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                }
                if parts.close != nil {
                    Button(action: closeCard) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: style.number("close", "size")))
                            .foregroundStyle(tone?.muted ?? style.color("close", "color"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                if let accessory, !placeholder {
                    accessoryView(accessory, tone: tone)
                }
            }
            if let failed {
                HStack(spacing: 8) {
                    Label("Couldn't load this", systemImage: "exclamationmark.triangle")
                        .font(style.theme.font(size: 13, weight: .regular))
                        .foregroundStyle(tone?.muted ?? style.color("body", "color"))
                        .accessibilityHint(failed)
                    Button("Try again", action: retry)
                        .font(style.theme.font(size: 13, weight: .semibold))
                        .tint(tone?.accent ?? style.color("buttons", "color"))
                }
            }
            if !buttons.isEmpty {
                buttonsRow(buttons, tone: tone)
            }
            }
            .padding(style.number("surface", "padding"))
            // Bleeding under the status bar: the surface runs up, the content
            // stays below it (a picture across the top runs up with the surface).
            .padding(.top, top == nil ? bleed?.underTop ?? 0 : 0)
            // `overlap`: empty surface at the bottom for what follows to cover.
            .padding(.bottom, cardOverlap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tone?.fill ?? style.color("surface", "fill")))
        .clipShape(shape)
        .overlay {
            if style.number("surface", "border", "width") > 0 {
                shape.stroke(style.color("surface", "border", "color"), lineWidth: style.number("surface", "border", "width"))
            }
        }
        .shadow(color: style.rgba("surface", "shadow", "color").withAlpha(Double(style.number("surface", "shadow", "opacity"))).color,
                radius: style.number("surface", "shadow", "radius"), y: style.number("surface", "shadow", "offsetY"))
        .contentShape(shape)
        .redacted(reason: placeholder ? .placeholder : [])

        Group {
            if let tap, !placeholder {
                content.onTapGesture { perform(tap) }.accessibilityAddTraits(.isButton)
            } else {
                content
            }
        }
        .cmsInspectorID("Cms.cards.card")
    }

    // MARK: Text

    @ViewBuilder
    private func textParts(tone: CmsResolvedCardStyle.Tone?) -> some View {
        if let eyebrow = parts.eyebrow {
            line(eyebrow, look: "eyebrow", color: tone?.muted, relativeTo: .caption, uppercase: style.flag("eyebrow", "uppercase"),
                 tracking: style.number("eyebrow", "letterSpacing"))
        }
        if let title = parts.title { line(title, look: "title", color: tone?.text, relativeTo: .headline) }
        if let body = parts.body { line(body, look: "body", color: tone?.text, relativeTo: .body) }
        if let value = parts.value { line(value, look: "value", color: tone?.text, relativeTo: .largeTitle) }
        if let figures = parts.figures, !figures.isEmpty {
            HStack(alignment: .top, spacing: style.number("figures", "gap")) {
                ForEach(figures.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(figures[i].label)
                            .modifier(CmsScaledFont(theme: style.theme, size: style.number("figures", "labelSize"),
                                                    weight: .regular, relativeTo: .caption))
                            .foregroundStyle(tone?.muted ?? style.color("figures", "labelColor"))
                        filled(figures[i].value) { text in
                            Text(text)
                                .modifier(CmsScaledFont(theme: style.theme, size: style.number("figures", "valueSize"),
                                                        weight: CmsTypography.weight(css: Double(style.number("figures", "valueWeight"))),
                                                        relativeTo: .headline))
                                .foregroundStyle(tone?.text ?? style.color("figures", "valueColor"))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if let lines = parts.lines {
            ForEach(lines.indices, id: \.self) { i in
                let listStyle = style.listStyle
                HStack(spacing: 6) {
                    if let image = lines[i].image, !column(image).pictureCandidates(instance.row ?? [:]).isEmpty {
                        CmsColumnPicture(candidates: column(image).pictureCandidates(instance.row ?? [:]),
                                         size: listStyle.inlineImageSize, cornerRadius: listStyle.inlineImageRadius)
                            .accessibilityHidden(true)
                    }
                    filled(lines[i]) { text in
                        Text(text)
                            .modifier(listStyle.scaledFont(listStyle.style.lines?.size, fallback: 14,
                                                           weight: listStyle.style.lines?.weight, relativeTo: .subheadline))
                            .foregroundStyle(tone?.muted ?? listStyle.color(listStyle.style.lines?.color) ?? listStyle.subtitleColor)
                    }
                }
            }
        }
        if let chip = parts.chip, let row = instance.row, let look = column(chip).chip(row) {
            CmsChipView(style: style.listStyle, chip: look)
        }
    }

    private func line(_ line: CmsCardLine, look: String, color: Color?, relativeTo: Font.TextStyle,
                      uppercase: Bool = false, tracking: CGFloat = 0) -> some View {
        filled(line, uppercase: uppercase) { text in
            Text(text)
                .tracking(tracking)
                .modifier(CmsScaledFont(theme: style.theme, size: style.number(look, "size"),
                                        weight: CmsTypography.weight(css: Double(style.number(look, "weight"))),
                                        relativeTo: relativeTo))
                .foregroundStyle(color ?? style.color(look, "color"))
        }
    }

    /// A line's words, or a placeholder of the same look while a source it
    /// reads is still coming. While a written card's query loads, only that
    /// query's slots are placeholders, inline, and the words around them and
    /// built-in slots (`{today}`) draw at once. An empty line draws nothing.
    @ViewBuilder
    private func filled<V: View>(_ line: CmsCardLine, uppercase: Bool = false,
                                 @ViewBuilder _ draw: (AttributedString) -> V) -> some View {
        let slots = CmsListRowLayout.slots(line.text).map { CmsCards.splitSlot($0).column }
        let waiting = slots.contains { slot in
            guard let dot = slot.firstIndex(of: ".") else { return false }
            return pendingAlias(String(slot[..<dot]))
        }
        let cased: (String) -> String = { uppercase ? $0.uppercased() : $0 }
        if waiting {
            draw(AttributedString("Loading value")).redacted(reason: .placeholder)
        } else if queryWaiting, let row = CmsCards.waitingRow(for: line.text, row: instance.row) {
            let words = CmsListRowLayout.fill(line.text, row: row, column: column)
                .map { runtime.resolveTemplate($0, rowContext: row) } ?? CmsCards.waitingMark
            draw(waitingText(CmsCards.waitingSegments(words), cased: cased))
                .accessibilityLabel(Text(cased(words.replacingOccurrences(of: CmsCards.waitingMark, with: "loading"))))
        } else if let text = filledText(line.text) {
            draw(AttributedString(cased(text)))
        }
    }

    /// Words with an inline placeholder for each slot still waiting: the
    /// slot's room in the line's own font, filled with the system fill.
    private func waitingText(_ segments: [(text: String, placeholder: Bool)],
                             cased: (String) -> String) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            if segment.placeholder {
                var mark = AttributedString("\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}")
                mark.backgroundColor = Color.ripul(system: .systemFill)
                out += mark
            } else {
                out += AttributedString(cased(segment.text))
            }
        }
        return out
    }

    private func filledText(_ text: String) -> String? {
        // A written card without a query still fills built-in slots ({today}).
        let words = CmsListRowLayout.fill(text, row: instance.row ?? [:], column: column)
        return words.map { runtime.resolveTemplate($0, rowContext: instance.row) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Media

    @ViewBuilder
    private func mediaView(_ media: CmsCardMedia, top: Bool, tone: CmsResolvedCardStyle.Tone?) -> some View {
        let size = style.number("media", "size")
        let shapeName = style.string("media", "shape") ?? "roundedSquare"
        let radius: CGFloat = shapeName == "circle" ? size / 2 : shapeName == "square" || shapeName == "none" ? 0 : size * 0.25
        let glyphColour = tone?.text ?? style.color("media", "tint")
        switch media {
        case .symbol(let name) where shapeName == "none":
            // No tile: the symbol fills the size, as an app's own glyph does.
            Image(systemName: CmsNavIcon.symbol(for: name) ?? name)
                .resizable().scaledToFit()
                .foregroundStyle(glyphColour)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .glyph(let source):
            let candidates = CmsCards.mediaCandidates(source, chain: [], row: instance.row, column: column)
            if !candidates.isEmpty {
                CmsColumnPicture(candidates: candidates, size: size, cornerRadius: 0, template: glyphColour)
                    .padding(shapeName == "none" ? 0 : size * 0.2)
                    .frame(width: size, height: size)
                    .background(shapeName == "none" ? nil : RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(tone.map { $0.text.opacity(0.18) } ?? style.color("media", "fill")))
                    .accessibilityHidden(true)
            }
        case .symbol(let name):
            Image(systemName: CmsNavIcon.symbol(for: name) ?? name)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tone?.text ?? style.color("media", "tint"))
                .frame(width: size, height: size)
                // On a toned card the badge is the tone's text colour at 18%, the
                // symbol in it (the web's rule), so the symbol reads.
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tone.map { $0.text.opacity(0.18) } ?? style.color("media", "fill")))
                .accessibilityHidden(true)
        case .image(let source, let chain):
            let candidates = CmsCards.mediaCandidates(source, chain: chain, row: instance.row, column: column)
            if !candidates.isEmpty {
                if top {
                    CmsChainImage(candidates: candidates)
                        .frame(maxWidth: .infinity)
                        .frame(height: style.number("media", "topHeight"))
                        .clipped()
                } else {
                    // No tile: the picture whole, in its own colours, as an app's own icon.
                    CmsColumnPicture(candidates: candidates, size: size, cornerRadius: radius, fit: shapeName == "none")
                }
            }
        case .date(let columnName):
            let parts = CmsListRowLayout.dateParts(instance.row.flatMap { CmsColumnPresentation.field($0, columnName) })
            if parts != nil {
                CmsDateBlock(style: style.listStyle, parts: parts)
                    .frame(width: size + 8)
            }
        }
    }

    // MARK: The accessory

    /// A round button at the top trailing corner: the picture when there is one,
    /// else the initials of its name, else its symbol; the tone's text on 18% of it,
    /// as a toned card's symbol badge.
    private func accessoryView(_ accessory: CmsCardAccessory, tone: CmsResolvedCardStyle.Tone?) -> some View {
        let size = accessory.size
        let text = tone?.text ?? style.color("title", "color")
        let name = accessory.initials.flatMap(filledText)
        let initials = CmsCardAccessory.initials(name)
        let candidates = accessory.image.map { CmsCards.mediaCandidates($0, chain: [], row: instance.row, column: column) } ?? []
        return Button { perform(accessory.action) } label: {
            ZStack {
                Circle().fill(text.opacity(0.18))
                if initials.isEmpty {
                    Image(systemName: CmsNavIcon.symbol(for: accessory.symbol ?? "person") ?? "person.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                } else {
                    Text(initials)
                        .font(style.theme.font(size: size * 0.4, weight: .bold))
                        .minimumScaleFactor(0.6)
                }
                if !candidates.isEmpty {
                    CmsColumnPicture(candidates: candidates, size: size, cornerRadius: size / 2)
                }
            }
            .foregroundStyle(text)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessory.label)
        .accessibilityIdentifier("Cms.cards.card.accessory")
    }

    // MARK: Buttons

    private func buttonsRow(_ buttons: [CmsCardButton], tone: CmsResolvedCardStyle.Tone?) -> some View {
        let colour = tone?.accent ?? style.color("buttons", "color")
        let iconSize = style.number("buttons", "iconSize")
        return HStack(spacing: style.number("buttons", "gap")) {
            ForEach(buttons.indices, id: \.self) { i in
                let b = buttons[i]
                if b.look == "icon" {
                    // Only the icon or picture; the label is what VoiceOver says.
                    Button { perform(b.action) } label: {
                        buttonIcon(b, colour: colour, size: iconSize)
                            .frame(width: max(44, iconSize), height: max(44, iconSize))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.label)
                    .disabled(placeholder)
                } else {
                    Button { perform(b.action) } label: {
                        HStack(spacing: 6) {
                            if b.image != nil {
                                buttonIcon(b, colour: b.look == "filled" ? style.color("buttons", "onColor") : colour,
                                           size: style.number("buttons", "size") + 2)
                            }
                            else if let symbol = CmsNavIcon.symbol(for: b.icon) { Image(systemName: symbol) }
                            Text(b.label)
                        }
                    }
                    .buttonStyle(CmsCardButtonStyle(look: b.look, style: style, accent: tone?.accent))
                    .disabled(placeholder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: style.string("buttons", "align") == "center" ? .center : .leading)
    }

    /// A button's picture as a glyph in its colour, else its symbol.
    @ViewBuilder
    private func buttonIcon(_ b: CmsCardButton, colour: Color, size: CGFloat) -> some View {
        if let image = b.image {
            let candidates = CmsCards.mediaCandidates(image, chain: [], row: instance.row, column: column)
            CmsColumnPicture(candidates: candidates, size: size, cornerRadius: 0, template: colour)
        } else if let symbol = CmsNavIcon.symbol(for: b.icon) ?? b.icon {
            Image(systemName: symbol).resizable().scaledToFit()
                .foregroundStyle(colour)
                .frame(width: size, height: size)
        }
    }
}

/// A card's button in the style's look: filled, outlined, tinted or plain.
struct CmsCardButtonStyle: ButtonStyle {
    let look: String
    let style: CmsResolvedCardStyle
    let accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        let colour = accent ?? style.color("buttons", "color")
        let shape = RoundedRectangle(cornerRadius: min(style.number("buttons", "cornerRadius"), 999), style: .continuous)
        return configuration.label
            .modifier(CmsScaledFont(theme: style.theme, size: style.number("buttons", "size"),
                                    weight: CmsTypography.weight(css: Double(style.number("buttons", "weight"))), relativeTo: .body))
            .foregroundStyle(look == "filled" ? style.color("buttons", "onColor") : colour)
            .padding(.horizontal, look == "plain" ? 0 : style.number("buttons", "paddingHorizontal"))
            .padding(.vertical, style.number("buttons", "paddingVertical"))
            .background {
                switch look {
                case "filled": shape.fill(colour)
                case "tinted": shape.fill(colour.opacity(0.12))
                case "outlined": shape.strokeBorder(colour, lineWidth: 1)
                default: Color.clear
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - The carousel

/// A paged sideways carousel: one card at a time, the system's page dots
/// and the count beside them, a height that follows the card on show (or the
/// tallest), a glimpse of the next, autoplay and loop. Also the section
/// carousel's pages.
struct CmsPagedCarousel<Page: View>: View {
    let ids: [String]
    let options: CmsCardsProps.Carousel
    let style: CmsResolvedCardStyle
    @ViewBuilder let page: (String) -> Page

    @State private var current: String?
    @State private var heights: [String: CGFloat] = [:]
    @Environment(\.cmsBleed) private var bleed

    private var index: Int { current.flatMap { ids.firstIndex(of: $0) } ?? 0 }

    var body: some View {
        let height = options.height == "tallest" ? heights.values.max() : heights[current ?? ids.first ?? ""]
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: style.number("carousel", "gap")) {
                    ForEach(ids, id: \.self) { id in
                        page(id)
                            // A card narrower than the block (a glimpse of the next one
                            // showing) keeps its radius inside a bleeding block.
                            .environment(\.cmsBleed, options.peek > 0 ? nil : bleed)
                            .containerRelativeFrame(.horizontal) { width, _ in max(width - options.peek, 0) }
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CmsCarouselHeights.self, value: [id: proxy.size.height])
                            })
                            .id(id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            .scrollClipDisabled()
            .frame(height: height)
            .animation(.snappy, value: height)
            .onPreferenceChange(CmsCarouselHeights.self) { heights.merge($0) { _, new in new } }
            if ids.count > 1 && options.indicator != "none" {
                HStack(spacing: 8) {
                    if options.indicator != "count" {
                        CmsPageDots(count: ids.count, current: index, style: style) { i in
                            withAnimation { current = ids[i] }
                        }
                        .fixedSize()
                    }
                    if options.indicator != "dots" {
                        Text("\(index + 1) of \(ids.count)")
                            .font(style.theme.font(size: style.number("carousel", "countSize"), weight: .regular))
                            .foregroundStyle(style.color("carousel", "countColor"))
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Card \(index + 1) of \(ids.count)")
            }
        }
        .onAppear { if current == nil { current = ids.first } }
        .task(id: "\(options.autoplayMs ?? 0)-\(ids.count)") {
            guard let ms = options.autoplayMs, ms > 0, ids.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                guard !Task.isCancelled else { return }
                let next = index + 1
                if next < ids.count { withAnimation { current = ids[next] } }
                else if options.loop { withAnimation { current = ids[0] } }
            }
        }
    }
}

private struct CmsCarouselHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The system's page dots (`UIPageControl`), in the style's colours; when
/// there are more dots than fit, they scroll as the system's do.
struct CmsPageDots: View {
    let count: Int
    let current: Int
    let style: CmsResolvedCardStyle
    let select: (Int) -> Void

    var body: some View {
        #if canImport(UIKit)
        CmsPageControl(count: count, current: current,
                       dot: UIColor(style.color("carousel", "dot")),
                       active: UIColor(style.color("carousel", "dotActive")),
                       select: select)
        #else
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? style.color("carousel", "dotActive") : style.color("carousel", "dot"))
                    .frame(width: 7, height: 7)
            }
        }
        #endif
    }
}

#if canImport(UIKit)
private struct CmsPageControl: UIViewRepresentable {
    let count: Int
    let current: Int
    let dot: UIColor
    let active: UIColor
    let select: (Int) -> Void

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.hidesForSinglePage = true
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.select = select
        control.numberOfPages = count
        control.currentPage = current
        control.pageIndicatorTintColor = dot
        control.currentPageIndicatorTintColor = active
    }

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    final class Coordinator: NSObject {
        var select: (Int) -> Void
        init(select: @escaping (Int) -> Void) { self.select = select }
        @objc func changed(_ control: UIPageControl) { select(control.currentPage) }
    }
}
#endif

/// A card held while its query loads: the system's placeholder look.
struct CmsCardsLoadingCard: View {
    let style: CmsResolvedCardStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.number("surface", "cornerRadius"), style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text("Loading this card").font(style.theme.font(size: style.number("title", "size"), weight: .semibold))
            Text("Loading the details of this card").font(style.theme.font(size: style.number("body", "size"), weight: .regular))
        }
        .padding(style.number("surface", "padding"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(style.color("surface", "fill")))
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading")
    }
}
