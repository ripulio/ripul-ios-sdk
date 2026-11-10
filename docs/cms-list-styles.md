# List styles on iPhone

A CMS site's theme can say how its lists look: as iOS's own inset grouped list (`system`), as edge-to-edge rows with separators (`plain`), or as a card per row (`cards`). A site can also define its own styles from these. WAC's card rows, for example, are a `cards` style with WAC's numbers. Nothing in the code knows WAC.

This page covers the iPhone renderer. The web half, the editor and the `check_site` rules are in `chrome-extension/docs/architecture/cmsListStyles.md`. The plan, with Peter's decision ("Go", 27 October 2026), is `docs/plans/cms-list-styles.md`.

## The shape

The site's theme (`CmsPortalThemeConfig`, set with `set_portal_theme`) gains two fields:

```json
{
  "defaultListStyle": "wac",
  "listStyles": {
    "wac": {
      "basedOn": "cards",
      "card": { "cornerRadius": 10, "shadow": { "radius": 10, "offsetY": 2, "opacity": 0.12 }, "gap": 14 },
      "row": { "minHeight": 76, "paddingHorizontal": 18 },
      "picture": { "size": 20, "badge": "circle", "badgeSize": 36, "badgeTint": "tint" },
      "title": { "size": 18, "weight": 500, "color": "text" }
    }
  }
}
```

- **Settings:**
  - `card`: corner radius, fill, border, shadow, gap and page background;
  - `row`: minimum height, padding, separators and chevron;
  - `picture`: size, and a badge (`none`, `circle` or `roundedSquare`) with its size and tint;
  - `title`, `subtitle` and `trailing`: size, weight and colour.

  Sizes are points.
- **Colours** name a palette role, never a value: `primary`, `secondary`, `accent`, `tint`, `background`, `paper`, `surfaceMuted`, `divider`, `text` (the text colour), `mutedText` (the secondary text colour), `success`, `warning`, `error`. In dark mode they come from the dark palette.
- **Unset settings** take the value of the built-in the style is based on (`basedOn`, unset = `system`). They are merged one object level at a time, so `card.shadow.radius` alone keeps the built-in's other shadow settings.
- **Bad values** are unset, so the built-in's value draws. That covers a wrong type, a colour that isn't a role and an unknown layout. A style that isn't an object is skipped. Decoding never fails a page.
- **A site can't redefine a built-in.** A `listStyles` key named `system`, `plain` or `cards` is ignored.

**Which style a list uses:** the block's own `listStyle`, else the theme's `defaultListStyle`, else `system`. A name that names no style is passed over (`check_site` reports it as `list-style-unknown`).

**The built-in values** are in `CmsListStyle.swift` (`CmsListStyle.system`, `.plain`, `.cards`). They are the web's table, `chrome-extension/packages/shared-types/src/cmsListStyles.builtin.json`. `CmsListStylesTests.testBuiltInsEqualTheSharedTable` decodes that file and compares it setting by setting, so the two sides cannot drift.

## How each layout is drawn

| Layout | In a CMS page | In a host's `List` |
|---|---|---|
| `system` | One rounded group (the card) holding the rows, with hairline separators starting under the text | `.insetGrouped`, iOS's own; only what the site set changes it |
| `plain` | Edge-to-edge rows on the card's fill, separators between | `.plain`, row background and page background from the style |
| `cards` | A card per row: the style's fill, corners, border and shadow, the style's gap between | `.grouped` with `listRowSpacing(gap)` and twice the gap between sections, each row's background a card inset 16 pt from the edges |

**A row:**
- the picture is an SF Symbol in `primary`, on the badge filled with `badgeTint` when the style has a badge;
- then the title, and the subtitle under it;
- then an accessory (a nav badge or a selection circle) and the trailing value;
- then the chevron, when the row goes somewhere and the style has one.

The padding and minimum height come from `row`.

**A site that sets nothing looks exactly as before.** When the resolved style is the bare built-in `system`, the grid list, record cards and field grids take their old code paths untouched. Any other style draws from its values, including a site's own style based on `system`.

**The blocks:**

- **The grid's native list** (`agGrid`, list presentation): title, subtitle, trailing value and chevron (for a drill link) in the style. Group headers stay as they are. A grid view can carry its own `listStyle`.
- **Record cards:**
  - `cards` draws a card per record from the style. The block's own `cardFrame` still wins setting by setting, and so does its `gap`.
  - `system` and `plain` draw the records as rows of one group, or as edge-to-edge rows.
  - A selected row has the `tint` wash.
- **Field grids** (flow layout): the fields become list rows, the label as the title and the value trailing, like a record in Settings. A picture field shows its card under its label. The grid layout (`layoutMode: grid`) is unchanged.
- **`linkList`** (new): see below.

## The page background and the site's font

- **Page background:** a native page (`CmsPageBody`, in `CmsPageView` and in each of `CmsAppView`'s tabs) paints the palette's `background` behind itself, under the large title and the bars, as iOS does with a grouped background. It does so only when the palette names one: its dark palette's in dark mode, falling back to the light one the way the web layers them. A site that names none keeps iOS's own system background (`CmsPortalTheme.setsPageBackground`, `CmsPageBackground`).
- **The site's font:** list rows draw in the first family of `typography.fontFamily` at the style's sizes and weights, when that family is installed on the device, else in the system font (`CmsPortalTheme.fontFamily`, `font(size:weight:)`). This covers the grid's list, record cards (their title, labels and values), field grids, the link list and its headings, and `CmsListRow`. A web stack such as `"'Avenir Next', sans-serif"` reads as Avenir Next; a generic family reads as the system font.

## Light, dark and the site's `mode`

- **Following the device:** `CmsRuntime.theme` and `themeConfig` are published, so when the colour scheme changes while the app is open (dark mode at sunset), every block redraws in the new palette. Before 27 October 2026 only views that happened to redraw for another reason followed, which left a screen half light and half dark until relaunch.
- **A site that forces a mode** (`mode: "light"` or `"dark"`, read as `CmsPortalThemeConfig.forcedColorScheme`):
  - `CmsAppView` sets it as the colour scheme for everything under it, and as the window's preferred scheme. So the status bar, the tab bar, the large titles and the pages agree.
  - An embedded `CmsPageView` sets it for its own content only. Its navigation bar belongs to the host's stack, so a host embedding a page in a site that forces a mode applies `.preferredColorScheme(config.forcedColorScheme)` around its own `NavigationStack`.
- **How it was checked:** an iPhone 17 simulator (iOS 26.4) switched to dark while a page was open; the whole page went dark within the 6 seconds before the picture. A site forcing light on a dark phone stayed light throughout under `CmsAppView`.

## Richer rows: a grid's `listRow`

Plan: `docs/plans/cms-list-rows.md` (Peter, "Go", 27 October 2026). A grid says which of its columns go in which part of a list row. Each column draws with its own presentation, and the list style says how each part looks. Nothing in the code knows shifts or WAC. Files: `CmsListRowLayout.swift` (the shape, filling slots, the date), `CmsColumnPresentation.swift` (style rules, chips, pictures), `CmsListRowLayoutViews.swift` (drawing).

```json
"listRow": {
  "leading": { "date": "day" },
  "title": "{hours}",
  "lines": ["{wac_in_at} – {wac_out_at}", { "text": "{job} • {role}", "image": "job" }],
  "trailing": "{pay}",
  "chip": "kind"
}
```

**How a row draws** (the grid's native list, whenever `listRow` is set, in any style, the bare `system` included):

- **Leading:**
  - A **date block** shows the weekday (`EEE`, in capitals when `leading.date.top.uppercase`) over the day of the month, in the viewer's time zone. A bare `YYYY-MM-DD` is that calendar day. A naive datetime counts as UTC unless the column's `timezone` is `local`. The web also reads it as local when the connection stores local time; the native renderer doesn't know a connection's storage yet, so set the column's `timezone` for such a connection.
  - **A picture** is a column's.
  - Its width is `leading.width`, which grows with Dynamic Type.
- **Title, then up to three lines.** Each `{column}` slot is that column's value through its own `transform` and `format`, or a matching style rule's `text`.
  - **Empty values:** an empty value draws as nothing, and so do the words joining it. "{job} • {role}" with no role reads "KFC", and "{a}, {b}, {c}" with b empty reads "a, c". A line whose slots are all empty is dropped. The web does the same.
  - **A line's picture:** a line may start with a column's picture, at `inlineImage` size and corners. While it loads, its place is held invisibly. A row with no picture, or one whose picture fails to load (a 404 from the image source included), draws none and takes no space, so the text starts at the line's edge.
- **Which columns it reads:** every column the grid configures (`columns`, `columnViewRef` or `columnDefsRef`), hidden ones included, whatever `nativeColumns` keeps, as the web does. So a chip finds its rules and a line its image chain even when the native grid shows a smaller set.
- **The title** keeps the style's `title.color` even when a column is a drill link: the row's tap drills.
- **Trailing value and chip:** `trailing.align` is `center`, `top`, or `spread` (the value at the top, the chip at the bottom).
- **Chevron:** when the row drills and the style has one.
- **Accessibility:** VoiceOver reads the row as one element, in order: date, title, lines, value, chip.
- **Text size:** every part scales with Dynamic Type relative to a text style (title and value: body; lines: subheadline; weekday and chip: caption; day: title 2). At the default size each is exactly the style's size. At accessibility sizes the row stacks, as iOS's own rows do: the date on one line ("SUN 25"), then the title and lines, then the value and chip.

**A column's chip** (`lozenge`, wherever the native renderer draws a column's chip):
- **Everything comes from one rule,** the first that holds and isn't `rowWide`, whatever it sets; later rules are never read (the web's `chipLook`):
  - **Words:** its `text` (with `{column}` and `{column|distance}`), else the value in the column's format.
  - **Icon:** its `icon` (a nav icon key), else `lozenge.icon`.
  - **Colours:** its `fg` and `bg` as a pair when it sets either (an unset one stays unset), else the lozenge's pair. With neither, the style's `chip.color`, then primary.
- **Variants:**
  - The variant is the lozenge's, else the style's `chip.variant`.
  - `filled` fills with the colour and writes the rule's `fg`, or white.
  - `outlined` draws a border and text in the colour.
  - `tinted` fills with the colour at 12% and writes in it.
- **Shape and size:** corners, border, text, padding and icon size come from the style's `chip`.

**A column's picture** (`image`):
- With `image.chain`, the calendar markers' chain (`{ column }` for an address column, `{ source, column }` for the site's image source), the picture loads through the page's `CmsMarkerImageCache` and the images route, with the same caches.
- Without a chain, the value itself is the address.
- Record cards' and field grids' picture fields honour `image.chain` too.
- So do a link list row's picture and the offers grid's logo (below and in [Pictures in more blocks](#pictures-from-image-sources-in-more-blocks)).

**Formats with quoted text** (`CmsFormatValue`, twin of `formatValue.ts`): `0.##"h"` draws 6 as "6h", `#,##0 "m"` as "1,285 m", `"£"#,##0.00` as "£72.00". Quoted text is never read as a token, so the `h` in `"h"` doesn't make a duration.

**The list style's new levers**, resolved like the others (merged one object at a time; a bad colour, variant or align takes the built-in's):
- `leading` (width, align, and the date's `top` and `bottom` text);
- `lines` (size, weight, colour, gap);
- `inlineImage` (size, corners);
- `chip` (variant, corners, border, text, padding, icon size, colour);
- `trailing.align`.

The built-ins' values are the shared table's, and the test holds them equal. They are also knobs of the `cmsList` kind (`leading.date.top.size` and the like).

**New nav icon keys:** `swap`, `check`, `sick` and `holiday`.

**Checked** on an iPhone 17 simulator (iOS 26.4), against the local stand-in server with a site style like WAC's `wac`:
- the shift row in light and dark;
- in the `system` style;
- at an accessibility text size.

## The link list

The `linkList` block draws rows that each open a page, like a settings screen. Its props are `items: NavItem[]` and `listStyle?`. The renderer is `CmsLinkListBlock.swift`.

- **A row:**
  - `icon` (the nav icon registry's key) is the picture, unless the item has an `image.chain`;
  - `image: { chain }` puts a picture from the chain in the style's picture slot, with the style's badge. The chain reads the item's own fields, since an item has no data row: `{ source: "logos", column: "label" }` asks the site's image source by the label, and `{ column: "logoUrl" }` takes an https address from the item's `logoUrl`. While the picture loads, its slot is held, invisibly. If nothing loads (a 404, a failed load), the icon shows; with no icon the row has no picture and takes no space for one;
  - `label` is the title and `description` the subtitle;
  - `badge` and `badgeTone` draw the nav pill;
  - the chevron shows for a row with `targetPageSlug` or `url`.
- **Tapping a row** runs the nav item's own action. A page goes through `runtime.navigate`, so inside `CmsAppView` it is pushed on the tab's stack. A url opens through `openURL`.
- **Sections:** an item with `heading: true` starts a section under that heading, drawn as iOS's grouped header. A heading with no rows after it is dropped.
- **Who sees a row** follows the nav blocks' rule (`visibility`, `requiredRoles`).
- **Ignored:** children, actions other than links, and slots.

## Pictures from image sources in more blocks

Plan `cms-image-sources-woven-in`, "Pictures in more blocks": every block that shows a picture can take one from the site's image sources. Each is the calendar markers' chain (`CmsCalendarDecorations.imageChain`). Each loads through the page's `CmsMarkerImageCache` and the images route, with the same caches and the same 404 rule (no picture, and no second ask in the session).

| Block | Prop | Chain read over | No picture |
|---|---|---|---|
| Grid list rows | a column's `image.chain` | the row | no space |
| Record cards, field grids | a picture field's `image.chain` | the row | the muted placeholder |
| Link list | `items[].image.chain` | the item's own fields | the item's icon, else no space |
| Offers grid | `logoImage.chain` | the offer's row, then its `logo_url` (not tried twice) | the offer's initials |

The offers grid matches the web's `offerLogoCandidates` (`offerGrid.ts`).

**Tests:**
- `CmsImageChainBlocksTests` (5): the item's chain and candidates, empty and plain-http values skipped, the offer's chain before `logo_url` without a repeat, no chain.
- `Tests/CmsAppViewHarness` `testPicturesFromImageChains`: link list rows from an https chain, and a 404 falling back to the icon.

**Checked** on the iPhone Duo simulator (iOS 27.1), as the site's owner in the CMS Test Bed, on `cal-markers-test`'s page `image-chain-check` with its `gh_avatars` source:
- a link list row's avatar from the source;
- a 404 from the source falling back to the icon;
- an offer's logo from the source;
- a 404 with no `logo_url` showing initials;
- a 404 falling back to `logo_url`.

The harness can't show the offers grid: it loads as an anonymous visitor, whose session token the server lets run no queries.

## The theme engine's `cmsList` kind

`CmsListStyleKind` (iOS) is the list style as a `RipulStyleKind` of the SDK's theme engine:
- its knobs are the settings as dotted keys (`card.cornerRadius`, `title.color`), with `layout` for `basedOn`;
- its built-in styles are `system`, `plain` and `cards`;
- its default tier is `system`.

A host that wants list styles in its own theme editor adds `RipulStyleKind.cmsList()` to its spec.

**A site's styles never go into the engine's live document.** That document belongs to the host app, which persists it and may publish it, and one app can show several sites. So the cascade is a pure function, `RipulStyleKind.resolve(element:style:namedStyles:overrides:)`, which the engine's own resolution now calls too. `CmsListStyleKind.resolve(config:block:)` passes the site's styles as the named styles. A test holds it equal to the renderer's resolution, `CmsPortalThemeConfig.listStyle(block:)`.

## A host's own screens (public API, iOS)

Inside `CmsAppView`, the site's theme reaches the host's tabs (`.cmsSiteTheme(runtime.themeConfig)` on each host tab). A host screen matches the site's lists with two modifiers and a row view:

```swift
// WAC Next's Account tab
struct AccountView: View {
    let email: String
    let signOut: () -> Void

    var body: some View {
        List {
            Section("Account") {
                CmsListRow("Email", systemImage: "envelope", trailing: email)
                    .cmsListRow()
                NavigationLink { NotificationsView() } label: {
                    CmsListRow("Notifications", subtitle: "Paydays and missed shifts", systemImage: "bell")
                }
                .cmsListRow()
            }
            Section {
                Button(role: .destructive, action: signOut) {
                    CmsListRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive)
                }
                .cmsListRow()
            }
        }
        .navigationTitle("Account")
        .cmsListStyle()          // the site's defaultListStyle; .cmsListStyle("wac") for a named one
    }
}
```

| API | What it does |
|---|---|
| `.cmsListStyle(_ name: String? = nil)` | Draws a `List` in the named style, else the site's default, else `system`. Puts the resolved style in the environment. |
| `.cmsListRow()` | One row's background (a card, for `cards`), separators, insets and height. |
| `CmsListRow(_:subtitle:systemImage:trailing:navigates:role:)` | A row's content in the style. `role: .destructive` draws the title in `error`. Leave `navigates` off inside a `NavigationLink`: the list draws the link's own chevron. |
| `.cmsSiteTheme(_ config:)` / `\.cmsSiteTheme` | A site's theme for a screen outside `CmsAppView`. With none, everything draws as `system`. |
| `\.cmsListStyle` | The resolved style (`CmsResolvedListStyle`), for a host drawing something of its own. |

## Files

| File | What it holds |
|---|---|
| `CmsRender/CmsListStyle.swift` | `CmsPaletteRole`, `CmsListLayout`, `CmsListStyle` (the shape, lenient decoding, `layered(over:)`), the built-ins, which style a list uses, `CmsResolvedListStyle` |
| `CmsRender/CmsListStyleViews.swift` | `CmsStyledRows` (the three layouts), `CmsListRowContent`, the picture and section header |
| `CmsRender/CmsListStyleHost.swift` | The public API for host screens (iOS) |
| `CmsRender/CmsListStyleKind.swift` | The `cmsList` style kind (iOS) |
| `CmsRender/CmsLinkListBlock.swift` | The `linkList` block |
| `CmsRender/CmsListRowLayout.swift` | A grid's `listRow`: decoding, filling `{column}` slots, the date block's parts |
| `CmsRender/CmsColumnPresentation.swift` | A column's style rules (conditions, words, icon, colours), chip and picture candidates |
| `CmsRender/CmsListRowLayoutViews.swift` | Drawing a `listRow`: the row, date block, chip, column pictures, fonts scaled with Dynamic Type |
| `CmsRender/CmsPortalTheme.swift` | `listStyles` and `defaultListStyle` on the theme config; `color(role:)` |
| `Tests/RipulAgentTests/CmsListStylesTests.swift` | The tests |

## Tests

`swift test --filter CmsListStylesTests` (macOS) runs 13 tests:
- the built-ins against the shared table, and the palette roles;
- decoding, including lenient decoding;
- the resolution order, the built-in names, and merging one level at a time;
- when a list counts as bare `system`;
- colours in light, in dark, with the theme pinned to light, and with no palette;
- link list sections and visibility.

Two more run on an iOS simulator (they need UIKit's theme engine):
- knobs round-trip;
- the engine's cascade equals the renderer's resolution.

## How it was checked

- **Where:** an iPhone 17 simulator (iOS 26.4), borrowed from Trainyard.
- **The app:** a scratch harness app drawing `CmsPageView` against a local stub of the CMS endpoints (the definition and the query's rows).
  - Why a stub: an anonymous site-key visitor can't run saved queries ("Site key authentication only supports /v1/chat/completions or /v1/files/upload").
  - The stub's site has the built-ins, a cards-based site style like WAC's, link lists, and pages of each block in each style.
- **What:** every page in light and dark, plus the Account screen above in `system`, `plain`, `cards` and the site style.
- **Unchanged look:** a page with no `listStyle` and the same page with `listStyle: "system"` drew the same.

## Limits

- `pageBackground` paints the page only behind a host's `List`. A CMS page keeps its own background, which is the theme's `background`, the built-ins' page background too.
- In a host `List` with `system`, iOS draws everything a site style leaves unset. So a site style based on `system` changes only the settings it names.
- The grid's group headers, and the record cards' header and fields inside a card, keep their own look. Only the card, the row padding and the title take the style.
- **The shadow's default role is `text`.** In dark mode that is a light colour, so the cards' shadow shows as a faint light glow. Simulator screenshots on 27 October 2026 show it. A site that wants no glow sets `card.shadow.color` in its style, or the shared table changes its default; both renderers follow the table.
- **An icon is drawn in `primary`.** A site whose dark palette leaves `primary` unset keeps the light one, which can be dark on a dark badge.
- **Navigation titles keep the system font.** A page's title could take the site's family only through UIKit's bar appearance: a probe finding the page's hosting controller and setting its `navigationItem.standardAppearance` and `scrollEdgeAppearance`. That copies a whole appearance, so it risks the bar's own surface (iOS 26's glass, the transparent scroll edge), and SwiftUI may reset it. Not built.
- **A list in the bare built-in `system` keeps the system font,** like everything else about its old look. A site that wants its family in lists names a style.
