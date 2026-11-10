import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SafariServices) && os(iOS)
import SafariServices
#endif

/// Native twin of `offerGrid` (OfferGridBlock.tsx + offerGrid.ts): a
/// marketplace of offers from a query — search, category chips and a grid of
/// offer cards; a card opens the offer with its code to copy and the button
/// to take it up. Read only.
///
/// Semantics mirrored from offerGrid.ts: a row needs a name and is dropped
/// when its status is hidden/off; `coming_soon` marks it Soon and swaps the
/// button for "Register interest"; only http(s)/mailto/tel links and http(s)
/// logos are used; categories in first-seen order with counts; search matches
/// every word over name, category, headline and description; live before
/// coming-soon, then sort, then name.
///
/// Also mirrored: further `sections` under their headings, locked until the
/// block's `unlock` holds (`offerUnlocked`), `benefits` as points and
/// `image_url` as the open offer's picture (`offerBenefits`), the search and
/// the chips optional, and `copyCodeOnAction` (the button copies the code,
/// then opens the link).
///
/// Presentation: the brand band (heading, intro, a search field, the chips)
/// over a three-column card grid as in the wac app; the offer opens in a
/// sheet with a system Copy and the action button. An http(s) link opens in
/// Safari inside the app (SFSafariViewController), as WAC's Claim does;
/// mailto and tel go to the system.
struct CmsOfferGridBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @State private var query = ""
    @State private var category = ""
    @State private var open: Offer?

    struct Offer: Identifiable, Equatable {
        var id: String
        var name: String
        var category: String
        var headline: String
        var description: String
        var logo: URL?
        var link: URL?
        var code: String
        var comingSoon: Bool
        var sort: Double
        /// `offerBenefits`: a JSON list in text, a list, or one per line.
        var benefits: [String] = []
        /// `image_url`, http(s) only: the open offer's picture in place of the logo.
        var picture: URL?
        /// In a locked section not yet unlocked: no code, no button, the locked text.
        var locked = false
        /// The row the offer came from, for the logo's image chain.
        var row: [String: CmsJSON] = [:]
    }

    /// The logo's image chain (`logoImage.chain`), as a grid column's `image.chain`.
    private var logoChain: [CmsCalendarDecorations.ImageEntry] {
        CmsCalendarDecorations.imageChain(props["logoImage"]?.objectValue?["chain"])
    }

    /// `offerLogoCandidates`: the image chain over the offer's row first (an
    /// address in a column, or the site's image source asked by a value such
    /// as the name), then the offer's own `logo_url`.
    static func logoCandidates(_ offer: Offer, chain: [CmsCalendarDecorations.ImageEntry]) -> [CmsCalendarDecorations.ImageCandidate] {
        var out = CmsCalendarDecorations.imageCandidates(offer.row, chain)
        if let logo = offer.logo?.absoluteString, !out.contains(.url(logo)) { out.append(.url(logo)) }
        return out
    }

    private var props: [String: CmsJSON] { block.props }
    private func text(_ key: String, _ fallback: String) -> String {
        props.string(key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    private var querySlug: String { props.string("querySlug") ?? "" }

    /// `offerBenefits`.
    static func benefits(_ v: CmsJSON?) -> [String] {
        var items: [CmsJSON] = []
        switch v {
        case .array(let list)?:
            items = list
        case .string(let text)?:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("["), let data = t.data(using: .utf8), let list = try? JSONDecoder().decode([CmsJSON].self, from: data) {
                items = list
            } else {
                items = t.components(separatedBy: "\n").map(CmsJSON.string)
            }
        default:
            return []
        }
        return items
            .map { ($0 == .null ? "" : $0.displayString).trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: "^[•\\-*]\\s*", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    /// `offerUnlocked`: the unlock's column of its query's first row; with
    /// `equals`, compared as text, else any true value.
    static func unlocked(_ rows: [[String: CmsJSON]]?, unlock: [String: CmsJSON]?) -> Bool {
        guard let unlock, let slug = unlock.string("querySlug"), !slug.isEmpty,
              let column = unlock.string("column"), !column.isEmpty else { return false }
        let value = rows?.first?[column]
        if let equals = unlock["equals"], equals != .null {
            return (value.map { $0 == .null ? "" : $0.displayString } ?? "").trimmingCharacters(in: .whitespaces)
                == equals.displayString.trimmingCharacters(in: .whitespaces)
        }
        switch value {
        case .bool(let b)?: return b
        case .number(let n)?: return n == 1
        case .string(let t)?: return ["true", "1", "yes"].contains(t.trimmingCharacters(in: .whitespaces).lowercased())
        default: return false
        }
    }

    /// `offerFromRow`.
    static func offer(_ r: [String: CmsJSON], locked: Bool = false) -> Offer? {
        func str(_ key: String) -> String { (r[key].map { $0 == .null ? "" : $0.displayString } ?? "").trimmingCharacters(in: .whitespaces) }
        let name = str("name")
        let status = str("status").lowercased()
        guard !name.isEmpty, status != "hidden", status != "off" else { return nil }
        let logo = str("logo_url")
        let link = str("link_url")
        return Offer(
            id: str("id").isEmpty ? name : str("id"),
            name: name,
            category: str("category"),
            headline: str("headline"),
            description: str("description"),
            logo: logo.range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil ? URL(string: logo) : nil,
            link: link.range(of: "^(https?:|mailto:|tel:)", options: [.regularExpression, .caseInsensitive]) != nil ? URL(string: link) : nil,
            code: str("code"),
            comingSoon: status == "coming_soon" || status == "coming soon",
            sort: Double(str("sort")) ?? 0,
            benefits: benefits(r["benefits"]),
            picture: str("image_url").range(of: "^https?:", options: [.regularExpression, .caseInsensitive]) != nil ? URL(string: str("image_url")) : nil,
            locked: locked,
            row: r
        )
    }

    /// `filterOffers`.
    static func filter(_ offers: [Offer], query: String, category: String) -> [Offer] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return offers
            .filter { category.isEmpty || $0.category == category }
            .filter { o in
                guard !words.isEmpty else { return true }
                let hay = ([o.name, o.category, o.headline, o.description] + o.benefits).joined(separator: " ").lowercased()
                return words.allSatisfy(hay.contains)
            }
            .sorted { a, b in
                if a.comingSoon != b.comingSoon { return !a.comingSoon }
                if a.sort != b.sort { return a.sort < b.sort }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
    }

    private var offers: [Offer]? {
        guard case .ok(let result) = runtime.state(for: querySlug) else { return nil }
        return result.rows.compactMap { Self.offer($0) }
    }

    /// `sections`: each with a query, an optional heading and `locked`.
    private var sections: [(slug: String, heading: String, locked: Bool)] {
        guard case .array(let list)? = props["sections"] else { return [] }
        return list.compactMap { item in
            guard let o = item.objectValue, let slug = o.string("querySlug"), !slug.isEmpty else { return nil }
            return (slug, o.string("heading") ?? "", o.bool("locked") ?? false)
        }
    }

    private var unlockSlug: String { props.object("unlock")?.string("querySlug") ?? "" }

    private var isUnlocked: Bool {
        guard !unlockSlug.isEmpty, case .ok(let result) = runtime.state(for: unlockSlug) else { return false }
        return Self.unlocked(result.rows, unlock: props.object("unlock"))
    }

    private func sectionOffers(_ section: (slug: String, heading: String, locked: Bool), unlocked: Bool) -> [Offer] {
        guard case .ok(let result) = runtime.state(for: section.slug) else { return [] }
        return result.rows.compactMap { Self.offer($0, locked: section.locked && !unlocked) }
    }

    var body: some View {
        let offers = self.offers ?? []
        let unlocked = isUnlocked
        let sections = self.sections
        let more = sections.map { sectionOffers($0, unlocked: unlocked) }
        let every = offers + more.flatMap { $0 }
        let showSearch = props.bool("search") ?? true
        let showCategories = props.bool("categories") ?? true
        var counts: [(String, Int)] = []
        for o in every where !o.category.isEmpty {
            if let i = counts.firstIndex(where: { $0.0 == o.category }) { counts[i].1 += 1 } else { counts.append((o.category, 1)) }
        }
        let shown = Self.filter(offers, query: query, category: category)
        let shownMore = more.map { Self.filter($0, query: query, category: category) }
        let nothingShown = shown.isEmpty && shownMore.allSatisfy(\.isEmpty)
        let onBrand = runtime.theme.primaryContrast
        let plain = props.string("band") == "none"
        let chipsShown = showCategories && counts.count > 1
        return VStack(spacing: 0) {
            if plain {
                // No band: the page's masthead carries the title and the cut-in.
                if showSearch || chipsShown {
                    VStack(alignment: .leading, spacing: 12) {
                        if showSearch { searchField(plain: true) }
                        if chipsShown { chipsRow(counts, total: every.count, plain: true) }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(text("heading", "Get on this"))
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(-0.4)
                        .foregroundColor(onBrand)
                    if let intro = props.string("intro"), !intro.isEmpty {
                        Text(intro).font(.system(size: 14.5)).foregroundColor(onBrand.opacity(0.88))
                    }
                    if showSearch { searchField(plain: false) }
                    if chipsShown { chipsRow(counts, total: every.count, plain: false) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 64 + 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))
            }

            Group {
                if querySlug.isEmpty {
                    note("Choose the offers query.")
                } else if self.offers == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(24).background(card)
                } else if nothingShown {
                    note(text("emptyText", "No offers here yet."))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if !shown.isEmpty { grid(shown) }
                        ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                            if i < shownMore.count, !shownMore[i].isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    if !section.heading.isEmpty {
                                        Text(section.heading)
                                            .font(.ripul(.title3).weight(.heavy))
                                            .foregroundColor(runtime.theme.textPrimary)
                                            .accessibilityAddTraits(.isHeader)
                                            .padding(.horizontal, 4)
                                    }
                                    grid(shownMore[i])
                                }
                                .padding(.top, 24)
                                .cmsInspectorID("Cms.offerGrid.section")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, plain ? 0 : 12)
            .padding(.top, plain ? 0 : -64)
        }
        .onAppear {
            runtime.ensureLoaded(querySlug)
            for section in sections { runtime.ensureLoaded(section.slug) }
            if !unlockSlug.isEmpty { runtime.ensureLoaded(unlockSlug) }
        }
        .ripulSheet(item: $open, size: .form) { offer in
            CmsOfferSheet(offer: offer, logoCandidates: Self.logoCandidates(offer, chain: logoChain), actionLabel: text("actionLabel", "Get the offer"),
                          interestLabel: text("interestLabel", "Register interest"),
                          lockedText: text("lockedText", "This offer is for members only."),
                          copyCodeOnAction: props.bool("copyCodeOnAction") ?? false)
                .environmentObject(runtime)
        }
    }

    private func grid(_ list: [Offer]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(list) { offerCard($0) }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(runtime.theme.paper)
            .shadow(color: runtime.theme.textPrimary.opacity(0.08), radius: 5, y: 2)
    }

    private func note(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(runtime.theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(card)
    }

    private func searchField(plain: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(runtime.theme.textSecondary)
            TextField(text("searchPlaceholder", "Search offers"), text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(runtime.theme.textSecondary)
                    .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Capsule().fill(runtime.theme.paper))
        .overlay { if plain { Capsule().strokeBorder(runtime.theme.textPrimary.opacity(0.12)) } }
        .cmsInspectorID("Cms.offerGrid.search")
    }

    private func chipsRow(_ counts: [(String, Int)], total: Int, plain: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("", text("allLabel", "All"), total, plain: plain)
                ForEach(counts, id: \.0) { chip($0.0, $0.0, $0.1, plain: plain) }
            }
        }
    }

    private func chip(_ value: String, _ label: String, _ count: Int, plain: Bool) -> some View {
        let on = category == value
        let onBrand = runtime.theme.primaryContrast
        let primary = runtime.theme.primary
        // On the band: light chips on the brand colour. Plain: the brand colour on the page.
        let fill = plain ? (on ? primary : primary.opacity(0.1)) : (on ? onBrand : onBrand.opacity(0.16))
        let ink = plain ? (on ? onBrand : primary) : (on ? primary : onBrand)
        return Button { category = value } label: {
            HStack(spacing: 6) {
                Text(label)
                Text("\(count)").opacity(0.7)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .cmsInspectorID("Cms.offerGrid.category")
    }

    private func offerCard(_ offer: Offer) -> some View {
        Button { if !runtime.isDesignMode { open = offer } } label: {
            VStack(spacing: 6) {
                CmsOfferLogo(offer: offer, candidates: Self.logoCandidates(offer, chain: logoChain), size: 56)
                    .frame(height: 84)
                Text(offer.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(runtime.theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !offer.headline.isEmpty {
                    Text(offer.headline)
                        .font(.system(size: 12))
                        .foregroundColor(runtime.theme.textPrimary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
            .background(card)
            .overlay(alignment: .topLeading) {
                if offer.comingSoon {
                    Text("SOON")
                        .font(.system(size: 9.5, weight: .heavy))
                        .tracking(0.5)
                        .foregroundColor(runtime.theme.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(runtime.theme.tint))
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if offer.locked {
                    Label(text("lockedTag", "Members").uppercased(), systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9.5, weight: .heavy))
                        .tracking(0.5)
                        .foregroundColor(runtime.theme.primaryContrast)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(runtime.theme.primary))
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offer.locked ? "\(offer.name), \(text("lockedTag", "Members"))" : offer.name)
        .cmsInspectorID("Cms.offerGrid.card")
    }
}

/// An offer's logo: the first of its candidates that loads, through the
/// page's image cache (the same route and caches as list rows and the
/// calendar), or its initials on the secondary colour when it has none or
/// none loads.
struct CmsOfferLogo: View {
    let offer: CmsOfferGridBlockView.Offer
    let candidates: [CmsCalendarDecorations.ImageCandidate]
    let size: CGFloat
    @EnvironmentObject var runtime: CmsRuntime
    @State private var load = CmsPictureLoad.loading

    var body: some View {
        Group {
            switch load {
            case .loaded(let image):
                Image(cmsPlatformImage: image).resizable().scaledToFit().frame(maxHeight: size)
            case .loading:
                Color.clear.frame(width: size, height: size)
            case .none:
                initials
            }
        }
        .task(id: candidates) {
            guard !candidates.isEmpty else { load = .none; return }
            let image = await CmsMarkerImageCache.forPage(runtime)
                .resolve(candidates, size: CmsCalendarDecorations.imageRequestSize(Double(size)))
            load = CmsPictureLoad(image)
        }
    }

    private var initials: some View {
        let letters = offer.name.split(whereSeparator: \.isWhitespace).prefix(2)
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
        return Text(letters)
            .font(.system(size: size * 0.32, weight: .heavy))
            .foregroundColor(runtime.theme.secondaryContrast)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(runtime.theme.secondary))
    }
}

private struct CmsOfferSheet: View {
    let offer: CmsOfferGridBlockView.Offer
    let logoCandidates: [CmsCalendarDecorations.ImageCandidate]
    let actionLabel: String
    let interestLabel: String
    let lockedText: String
    let copyCodeOnAction: Bool
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    /// An http(s) link shown in Safari inside the app.
    @State private var browsing: CmsOfferBrowserLink?

    private func copyCode() {
        #if canImport(UIKit)
        UIPasteboard.general.string = offer.code
        #endif
        copied = true
    }

    private func take(_ link: URL) {
        if copyCodeOnAction && !offer.code.isEmpty { copyCode() }
        #if canImport(SafariServices) && os(iOS)
        if let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            browsing = CmsOfferBrowserLink(url: link)
            return
        }
        #endif
        openURL(link)
    }

    var body: some View {
        let onBrand = runtime.theme.primaryContrast
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    sheetPicture
                        .frame(width: 88, height: 88)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(runtime.theme.paper))
                        .padding(.bottom, 12)
                    if !offer.category.isEmpty {
                        Text(offer.category.uppercased())
                            .font(.system(size: 11, weight: .bold)).tracking(1.2)
                            .foregroundColor(onBrand.opacity(0.85))
                    }
                    Text(offer.name).font(.system(size: 22, weight: .heavy)).foregroundColor(onBrand)
                    if !offer.headline.isEmpty {
                        Text(offer.headline).font(.system(size: 15)).foregroundColor(onBrand.opacity(0.92))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(runtime.theme.gradient)

                VStack(alignment: .leading, spacing: 16) {
                    if !offer.description.isEmpty {
                        Text(offer.description).font(.system(size: 15)).foregroundColor(runtime.theme.textPrimary)
                    }
                    if !offer.benefits.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(offer.benefits.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundColor(runtime.theme.primary)
                                    Text(point).foregroundColor(runtime.theme.textPrimary)
                                }
                                .font(.system(size: 15))
                            }
                        }
                        .cmsInspectorID("Cms.offerGrid.sheet.benefits")
                    }
                    if offer.locked {
                        Label(lockedText, systemImage: "lock.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(runtime.theme.textPrimary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(runtime.theme.tint))
                            .cmsInspectorID("Cms.offerGrid.sheet.locked")
                    }
                    if !offer.locked && !offer.code.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("YOUR CODE").font(.system(size: 10.5, weight: .bold)).tracking(1)
                                    .foregroundColor(runtime.theme.textSecondary)
                                Text(offer.code).font(.system(size: 17, weight: .heavy)).tracking(0.6)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                copyCode()
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .tint(runtime.theme.primary)
                        }
                        .padding(12)
                        .padding(.leading, 4)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(runtime.theme.tint))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(runtime.theme.primary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    }
                    if !offer.locked, let link = offer.link {
                        Button { take(link) } label: {
                            Label(offer.comingSoon ? interestLabel : actionLabel, systemImage: "arrow.up.right")
                                .font(.system(size: 15, weight: .heavy))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(runtime.theme.primary)
                    }
                }
                .padding(20)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(onBrand)
                .padding(12)
                .accessibilityLabel("Close")
        }
        .cmsInspectorID("Cms.offerGrid.sheet")
        #if canImport(SafariServices) && os(iOS)
        .fullScreenCover(item: $browsing) { link in
            CmsOfferSafariView(url: link.url).ignoresSafeArea()
        }
        #endif
    }

    /// `image_url` when the offer has one, else its logo.
    @ViewBuilder private var sheetPicture: some View {
        if let picture = offer.picture {
            AsyncImage(url: picture) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().frame(maxWidth: 60, maxHeight: 60)
                } else if phase.error != nil {
                    CmsOfferLogo(offer: offer, candidates: logoCandidates, size: 60)
                } else {
                    ProgressView()
                }
            }
        } else {
            CmsOfferLogo(offer: offer, candidates: logoCandidates, size: 60)
        }
    }
}

struct CmsOfferBrowserLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if canImport(SafariServices) && os(iOS)
/// The system's in-app Safari, as WAC's Claim opens a partner's page.
private struct CmsOfferSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
