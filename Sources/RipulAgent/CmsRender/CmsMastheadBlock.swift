import SwiftUI

/// The `masthead` block, and the band a record form opened as a page sits
/// under: one of the theme's masthead styles (CmsMasthead.swift) with a title,
/// a subtitle and buttons. A page's `masthead` puts one first, bleeding and
/// pinned behind (CmsLevers); the band runs under the status bar there.
/// Buttons are the system's toolbar buttons in the navigation bar, not drawn
/// on the band. docs/cms-masthead.md.
struct CmsMastheadBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime
    @Environment(\.openURL) private var openURL
    /// The frame's `overlap`: the band grows by it, under what cuts in.
    @Environment(\.cmsOverlap) private var overlap
    /// A top bleed: the band runs under the status bar and keeps its text below it.
    @Environment(\.cmsBleed) private var bleed

    var body: some View {
        let style = CmsMasthead.style(runtime.themeConfig, named: block.props.string("style"))
        let actions = Self.actions(block.props["actions"])
        CmsMastheadBand(style: style,
                        theme: runtime.theme,
                        title: block.props.string("title"),
                        subtitle: block.props.string("subtitle"),
                        topInset: bleed?.underTop ?? 0,
                        extraBottom: overlap)
            .toolbar {
                if !actions.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        ForEach(actions.indices, id: \.self) { i in
                            let action = actions[i]
                            Button {
                                run(action)
                            } label: {
                                if let symbol = CmsNavIcon.symbol(for: action.icon) ?? action.icon.flatMap(Self.systemSymbol) {
                                    Label(action.label, systemImage: symbol)
                                } else {
                                    Text(action.label)
                                }
                            }
                            .cmsInspectorID("Cms.masthead.action")
                        }
                    }
                }
            }
    }

    struct Action {
        var label: String
        var icon: String?
        var actionType: String
        var pageSlug: String?
        var url: String?
        var edge: String?
    }

    static func actions(_ raw: CmsJSON?) -> [Action] {
        guard case .array(let list)? = raw else { return [] }
        return list.compactMap { item in
            guard let o = item.objectValue, let label = o.string("label"), !label.isEmpty, let type = o.string("actionType") else { return nil }
            return Action(label: label, icon: o.string("icon"), actionType: type, pageSlug: o.string("pageSlug"), url: o.string("url"), edge: o.string("edge"))
        }
    }

    /// An SF Symbol name written as the icon, when it is one.
    private static func systemSymbol(_ name: String) -> String? {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil ? name : nil
        #else
        return nil
        #endif
    }

    private func run(_ action: Action) {
        switch action.actionType {
        case "navigatePage":
            if let slug = action.pageSlug { runtime.navigate(toPage: slug, viewRef: nil) }
        case "openUrl":
            if let url = action.url.flatMap(URL.init(string:)), url.scheme == "https" || url.scheme == "http" { openURL(url) }
        case "openSidebar":
            runtime.openSidebar(edge: action.edge)
        default:
            break
        }
    }
}

/// The band: the style's fill (a palette role, or the brand gradient), its
/// title big and its subtitle muted, leading or centred, at least the style's
/// height, with the style's padding at the sides and under the text.
struct CmsMastheadBand: View {
    let style: CmsMasthead.Style
    let theme: CmsPortalTheme
    let title: String?
    let subtitle: String?
    /// Room above the text that the fill runs under: the status bar (a top
    /// bleed), or the status and navigation bars (a page-form, a host screen).
    var topInset: CGFloat = 0
    /// Extra fill under the text that a following surface covers, when the band
    /// isn't a block whose frame grows it (a form opened as a page).
    var extraBottom: CGFloat = 0

    var body: some View {
        let text = theme.color(role: style.text)
        let titleText = Self.fill(title)
        let subtitleText = Self.fill(subtitle)
        VStack(alignment: style.centred ? .center : .leading, spacing: 4) {
            if !titleText.isEmpty {
                Text(titleText)
                    .font(theme.font(size: style.titleSize, weight: Self.weight(style.titleWeight)))
                    .foregroundStyle(text)
                    .multilineTextAlignment(style.centred ? .center : .leading)
                    .lineLimit(style.centred ? 2 : 1)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
                    .cmsInspectorID("Cms.masthead.title")
            }
            if !subtitleText.isEmpty {
                Text(subtitleText)
                    .font(theme.font(size: style.subtitleSize, weight: .regular))
                    .foregroundStyle(text.opacity(style.subtitleOpacity))
                    .multilineTextAlignment(style.centred ? .center : .leading)
                    .cmsInspectorID("Cms.masthead.subtitle")
            }
        }
        // `height` is the text's room. A leading band has the padding above it too (WAC's
        // settings band: inset, one title line, inset); a centred one starts its text right
        // under the bars, as WAC's record masthead does, its metric level with the back button.
        .frame(maxWidth: .infinity, minHeight: style.height, alignment: style.centred ? .center : .leading)
        .padding(.horizontal, style.padding)
        .padding(.top, topInset + (style.centred ? 0 : style.padding))
        .padding(.bottom, style.padding + extraBottom)
        .background(CmsMastheadFill(style: style, theme: theme))
        .cmsInspectorID("Cms.masthead")
    }

    /// `{today}`, `{today|format}` and `{timeOfDay}` filled; other slots stay as written.
    static func fill(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let pattern = try? NSRegularExpression(pattern: #"\{([A-Za-z_]+)(?:\|([^}]*))?\}"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            let format = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            out += CmsLevers.builtIn(name, format: format) ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func weight(_ w: Double) -> Font.Weight {
        switch w {
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }
}

/// The `deviceSetting` block: a choice the viewer makes for this device only,
/// kept in the phone's own settings (`UserDefaults`). `setting:
/// "formPresentation"`: how record forms open, as a system `Picker` row.
/// Shows only when the theme's `formPresentation.viewerChoice` is on.
struct CmsDeviceSettingBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    var body: some View {
        if CmsMasthead.viewerChoiceAllowed(runtime.themeConfig) {
            CmsFormPresentationPicker(cmsId: runtime.cmsId,
                                      label: block.props.string("label") ?? "Forms open as",
                                      description: block.props.string("description"))
        } else if runtime.canDesign {
            Text("Viewers can't choose how forms open: turn on viewerChoice in the theme's formPresentation.")
                .font(.ripul(.caption))
                .foregroundStyle(.ripul(.textSecondary))
        }
    }
}

struct CmsFormPresentationPicker: View {
    let label: String
    let description: String?
    @AppStorage private var stored: String

    init(cmsId: String, label: String, description: String?) {
        self.label = label
        self.description = description
        _stored = AppStorage(wrappedValue: CmsMasthead.ViewerChoice.site.rawValue, CmsMasthead.storageKey(cmsId: cmsId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: Binding(
                get: { CmsMasthead.ViewerChoice(stored: stored) },
                set: { stored = $0.rawValue }
            )) {
                ForEach(CmsMasthead.ViewerChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .cmsInspectorID("Cms.deviceSetting.picker")
            if let description, !description.isEmpty {
                Text(description).font(.ripul(.footnote)).foregroundStyle(.ripul(.textSecondary))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ripul(system: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .cmsInspectorID("Cms.deviceSetting")
    }
}

/// The viewer's choice of how a site's record forms open, as one row for a
/// host app's own settings screen (WAC Next's Account): a system menu picker,
/// kept in `UserDefaults` under the same key the site's `deviceSetting` block
/// and a form's quick flip use. Offer it only where the site's theme has
/// `formPresentation.viewerChoice` on; elsewhere the choice is ignored.
public struct CmsFormPresentationSetting: View {
    let title: String
    let systemImage: String
    @AppStorage private var stored: String

    public init(cmsId: String, title: String = "Forms open as", systemImage: String = "rectangle.stack") {
        self.title = title
        self.systemImage = systemImage
        _stored = AppStorage(wrappedValue: CmsMasthead.ViewerChoice.site.rawValue, CmsMasthead.storageKey(cmsId: cmsId))
    }

    public var body: some View {
        Picker(selection: Binding(
            get: { CmsMasthead.ViewerChoice(stored: stored) },
            set: { stored = $0.rawValue }
        )) {
            ForEach(CmsMasthead.ViewerChoice.allCases, id: \.self) { choice in
                Text(choice.label).tag(choice)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .pickerStyle(.menu)
        .cmsInspectorID("Cms.formPresentationSetting")
    }
}

/// A masthead style's fill: a palette role, or the theme's brand gradient.
struct CmsMastheadFill: View {
    let style: CmsMasthead.Style
    let theme: CmsPortalTheme

    var body: some View {
        if let role = style.fill { theme.color(role: role) } else { theme.gradient }
    }
}

/// The site's masthead behind a scrolling screen (a `List` or `Form`): the band
/// under the status bar (and the navigation bar, when there is one) with the
/// title big in it, the first section starting the style's `overlap` up into
/// it and scrolling over it, and a strip of the band's fill over the status
/// and navigation bars so nothing slides under them uncovered. Page-forms and
/// host screens (`cmsSiteMasthead`) share it.
struct CmsMastheadChrome: ViewModifier {
    let style: CmsMasthead.Style
    let theme: CmsPortalTheme
    let title: String
    let subtitle: String?
    /// A grouped list's own room above its first section, given back so the
    /// first card starts exactly `overlap` into the band.
    var listTopMargin: CGFloat = 0
    /// `under`: the list is cut at the cut-in line (the band's foot less the
    /// overlap), so it goes under the band there and never covers it, as WAC's
    /// record and hub screens do. `rounded` keeps the cards' top corners at the
    /// line (`cutRadius`, the cards `cutInset` from the sides).
    var under = false
    var rounded = true
    var cutInset: CGFloat = CmsMastheadChrome.formInset
    var cutRadius: CGFloat = CmsMastheadChrome.formRadius
    @State private var bandHeight: CGFloat = 0
    @State private var safeTop: CGFloat = 0

    /// A system inset grouped list's sides and corners (a Form's cards).
    static let formInset: CGFloat = 20
    static var formRadius: CGFloat {
        if #available(iOS 26, macOS 26, *) { return 26 }
        return 10
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { safeTop = $0 }
            // A fixed line on the screen: the list scrolls beneath it, so nothing is
            // worked out per frame. Its coordinates are the screen's (the mask ignores
            // the safe area), where the band's foot is the bars plus its height.
            .mask {
                if under {
                    CmsBelowLine(cut: safeTop + bandHeight - style.overlap,
                                 radius: rounded ? cutRadius : 0, inset: cutInset)
                        .ignoresSafeArea()
                } else {
                    Rectangle().ignoresSafeArea()
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, max(0, bandHeight - style.overlap - listTopMargin), for: .scrollContent)
            .background(alignment: .top) {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        CmsMastheadBand(style: style, theme: theme, title: title, subtitle: subtitle,
                                        topInset: geometry.safeAreaInsets.top, extraBottom: style.overlap)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height - geometry.safeAreaInsets.top }) { bandHeight = $0 }
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .background(theme.color(role: .background).ignoresSafeArea())
            }
            // What scrolls up goes under the band's colour at the status and
            // navigation bars, never under the bars uncovered.
            .overlay(alignment: .top) {
                Color.clear.frame(height: 0)
                    .background(CmsMastheadFill(style: style, theme: theme).ignoresSafeArea(edges: .top))
                    .allowsHitTesting(false)
            }
            #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
    }
}

#if os(iOS)
// The site's theme reaches host screens through `cmsSiteTheme`, an iOS-only key (CmsListStyleHost.swift).
public extension View {
    /// The site's masthead on a host app's own screen (a `List` or `Form`),
    /// the same band a CMS page shows: the theme's masthead style (`style`, a
    /// key of the site's `mastheads`; nil = its `defaultMasthead`), `title`
    /// big in it and `subtitle` under it, the list's first section cutting
    /// into it. The navigation bar is hidden at this screen's top. Inside
    /// `CmsAppView` the site's theme reaches host tabs (`cmsSiteTheme`);
    /// elsewhere the built-in style draws in the system's colours. Apply it
    /// before `cmsListStyle`, whose page colour would otherwise cover the band.
    ///
    /// `scroll` (`over` or `under`) and `cut` (`rounded` or `straight`) override
    /// the style's: `under` cuts the list at the cut-in line, so it scrolls under
    /// the band rather than over it, as WAC's screens do.
    func cmsSiteMasthead(_ title: String, subtitle: String? = nil, style: String? = nil,
                         scroll: String? = nil, cut: String? = nil) -> some View {
        modifier(CmsHostMasthead(title: title, subtitle: subtitle, style: style, scroll: scroll, cut: cut))
    }
}

private struct CmsHostMasthead: ViewModifier {
    let title: String
    let subtitle: String?
    let style: String?
    let scroll: String?
    let cut: String?
    @Environment(\.cmsSiteTheme) private var config
    @Environment(\.colorScheme) private var colorScheme
    /// Set by `cmsListStyle` around this modifier: where its cards sit, for the rounded cut.
    @Environment(\.cmsListStyle) private var listStyle

    func body(content: Content) -> some View {
        let resolved = CmsMasthead.style(config, named: style)
        let how = CmsMasthead.scrolling(resolved, scroll: scroll, cut: cut)
        let cards = listStyle?.layout == .cards
        content
            .modifier(CmsMastheadChrome(style: resolved,
                                        theme: CmsPortalTheme(config: config, effectiveDark: colorScheme == .dark),
                                        title: title, subtitle: subtitle,
                                        under: how.under, rounded: how.rounded,
                                        cutInset: cards ? 16 : CmsMastheadChrome.formInset,
                                        cutRadius: cards ? (listStyle?.cornerRadius ?? 10) : CmsMastheadChrome.formRadius))
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
    }
}
#endif
