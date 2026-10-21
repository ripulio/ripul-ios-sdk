import SwiftUI
#if canImport(UIKit)
import UIKit
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
/// Presentation: the brand band (heading, intro, a search field, the chips)
/// over a three-column card grid as in the wac app; the offer opens in a
/// sheet with a system Copy and a Link button.
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
    }

    private var props: [String: CmsJSON] { block.props }
    private func text(_ key: String, _ fallback: String) -> String {
        props.string(key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
    private var querySlug: String { props.string("querySlug") ?? "" }

    /// `offerFromRow`.
    static func offer(_ r: [String: CmsJSON]) -> Offer? {
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
            sort: Double(str("sort")) ?? 0
        )
    }

    /// `filterOffers`.
    static func filter(_ offers: [Offer], query: String, category: String) -> [Offer] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return offers
            .filter { category.isEmpty || $0.category == category }
            .filter { o in
                guard !words.isEmpty else { return true }
                let hay = [o.name, o.category, o.headline, o.description].joined(separator: " ").lowercased()
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
        return result.rows.compactMap(Self.offer)
    }

    var body: some View {
        let offers = self.offers ?? []
        var counts: [(String, Int)] = []
        for o in offers where !o.category.isEmpty {
            if let i = counts.firstIndex(where: { $0.0 == o.category }) { counts[i].1 += 1 } else { counts.append((o.category, 1)) }
        }
        let shown = Self.filter(offers, query: query, category: category)
        let onBrand = runtime.theme.primaryContrast
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(text("heading", "Get on this"))
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundColor(onBrand)
                if let intro = props.string("intro"), !intro.isEmpty {
                    Text(intro).font(.system(size: 14.5)).foregroundColor(onBrand.opacity(0.88))
                }
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
                .cmsInspectorID("Cms.offerGrid.search")
                if counts.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("", text("allLabel", "All"), offers.count)
                            ForEach(counts, id: \.0) { chip($0.0, $0.0, $0.1) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 64 + 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(runtime.theme.gradient, in: RoundedRectangle(cornerRadius: runtime.theme.cardRadius, style: .continuous))

            Group {
                if querySlug.isEmpty {
                    note("Choose the offers query.")
                } else if self.offers == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(24).background(card)
                } else if shown.isEmpty {
                    note(text("emptyText", "No offers here yet."))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(shown) { offerCard($0) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, -64)
        }
        .onAppear { runtime.ensureLoaded(querySlug) }
        .ripulSheet(item: $open, size: .form) { offer in
            CmsOfferSheet(offer: offer, actionLabel: text("actionLabel", "Get the offer"),
                          interestLabel: text("interestLabel", "Register interest"))
                .environmentObject(runtime)
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

    private func chip(_ value: String, _ label: String, _ count: Int) -> some View {
        let on = category == value
        let onBrand = runtime.theme.primaryContrast
        return Button { category = value } label: {
            HStack(spacing: 6) {
                Text(label)
                Text("\(count)").opacity(0.7)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(on ? runtime.theme.primary : onBrand)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(on ? onBrand : onBrand.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .cmsInspectorID("Cms.offerGrid.category")
    }

    private func offerCard(_ offer: Offer) -> some View {
        Button { if !runtime.isDesignMode { open = offer } } label: {
            VStack(spacing: 6) {
                CmsOfferLogo(offer: offer, size: 56)
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
        }
        .buttonStyle(.plain)
        .cmsInspectorID("Cms.offerGrid.card")
    }
}

/// An offer's logo, or its initials on the secondary colour when it has none
/// or it fails to load.
struct CmsOfferLogo: View {
    let offer: CmsOfferGridBlockView.Offer
    let size: CGFloat
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        if let url = offer.logo {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit().frame(maxHeight: size)
                case .failure: initials
                default: Color.clear.frame(width: size, height: size)
                }
            }
        } else {
            initials
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
    let actionLabel: String
    let interestLabel: String
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let onBrand = runtime.theme.primaryContrast
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    CmsOfferLogo(offer: offer, size: 60)
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
                    if !offer.code.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("YOUR CODE").font(.system(size: 10.5, weight: .bold)).tracking(1)
                                    .foregroundColor(runtime.theme.textSecondary)
                                Text(offer.code).font(.system(size: 17, weight: .heavy)).tracking(0.6)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = offer.code
                                #endif
                                copied = true
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
                    if let link = offer.link {
                        Link(destination: link) {
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
    }
}
