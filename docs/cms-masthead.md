# The site's masthead, and record forms as pages, on iPhone

This is the iPhone half of `docs/plans/cms-masthead-and-form-presentation.md`. The shapes, the rules and WAC's configuration are in `chrome-extension/docs/architecture/cmsMasthead.md`. The iPhone follows the same rules, held to `cmsMasthead.cases.json` by `CmsMastheadTests`.

| File | What it holds |
|---|---|
| `CmsMasthead.swift` | Styles (`CmsMasthead.style`), a page's masthead put first (`withMasthead`, `applied`), which way a form opens (`presentation`), and the viewer's choice in `UserDefaults` (`storageKey`, `ViewerChoice`) |
| `CmsMastheadBlock.swift` | The `masthead` block and its band (`CmsMastheadBand`), the `deviceSetting` block, and the public `CmsFormPresentationSetting` for a host app's own settings |
| `CmsRecordFormSheet.swift` | The form in `presentation: .page` (`CmsFormPageChrome`), and the presenter that sends every opener to a sheet or a pushed page (`CmsRecordFormPresenter`) |
| `CmsAppView.swift`, `CmsTabBar.swift` | Form routes (`CmsAppRoute.formID`) pushed on the selected tab's stack (`runtime.pushFormPage`, `closeFormPage`) |

## A page's masthead

- **How it's drawn:** `CmsPageBody` draws the page as `CmsMasthead.applied` makes it, with a `masthead` block first (bleed, pinned behind, overlapped) and the page's title hidden. The levers in `CmsLevers.swift` then run it under the status bar, keep it still and grow it under what cuts in (`overlapGrowsSurface` includes `masthead`).
- **The designer** edits the raw page JSON in `CmsDesignController`, so the band never reaches a save.
- **Buttons** are `ToolbarItemGroup(placement: .primaryAction)`: the system's own bar buttons, not drawn on the band.
- **The band** fills with a palette role or the theme's brand gradient (`runtime.theme.gradient`). Its title is `.system(size:weight:)` at the style's size, two lines at most, shrinking to fit.

## A record form as a page

`CmsRecordFormPresenter` sends every opener here: a row's `openRowForm`, a card's `open.form`, a calendar day's add, and an action button's own form, which now goes through the presenter as `CmsRecordFormRequest(mutationSlug:inputs:onSave:)`.

- **Where it goes:** when `CmsMasthead.presentation(of:runtime:)` is `.page` and `CmsAppView` can push, the form is pushed onto the selected tab's `NavigationStack` as a form route. A host tab's stack is the host's own, so there it opens as a sheet.
- **The masthead:**
  - The band is the form's style, drawn behind the form under the status and navigation bars (`CmsFormPageChrome`), with the form's title big and its `subtitle` under it.
  - The `Form`'s background is hidden and its top margin is set so the first section starts `overlap` up into the band. The bar's background is hidden.
  - Text that sits on the band takes the band's text colour: the first section's heading, and a step's title and question.
- **Back:**
  - With nothing changed it is the system's back button, and swiping back works.
  - With changes it is a Back button that asks "Discard your changes?", as a sheet can't be swiped away while it has changes.
  - Saving or deleting pops the form and its steps (`closeFormPage`).
- **Steps** are pushed on the same stack, each step presenting the next (`navigationDestination(isPresented:)`).
  - Only a step that exists builds the next one. The first build built destinations without end and crashed WAC Next.
  - On a page-form, a step's question is the band's title and its progress and title ("Step 2 of 3 · Dates") are the band's subtitle, so nothing straddles the band's edge.
- **The runtime:** what a page-form pushes (the next step, a `list` choice's screen) is given the runtime as an environment object. A destination takes the tab stack's environment, not the form's, and a pushed room list crashed the Playground without it.
- **The quick flip:** with `viewerChoice` on, the bar's overflow menu (`.secondaryAction`) has "Open as page" or "Open as sheet". It closes the form, stores the choice and opens it the other way, after the close has finished, with what was typed (`CmsRecordFormRequest.draft`).

## A host app's own screen: `cmsSiteMasthead`

```swift
List { … }
    .cmsSiteMasthead("Account")      // style: nil = the site's defaultMasthead
    .cmsListStyle("wacHub")          // after it: the list style's page colour sits behind the band
```

- **What it draws:** the same band CMS pages show (`CmsMastheadChrome`, shared with page-forms), behind a `List` or `Form`.
  - The navigation bar is hidden, and the band runs under the status bar with its title below it.
  - The list's first section starts the style's `overlap` up into the band.
  - A strip of the band's fill covers the bars, so rows that scroll up go under the band's colour and never under the status bar uncovered.
- **The theme:** inside `CmsAppView`, host tabs get the site's theme (`cmsSiteTheme`). Elsewhere the built-in style draws in the system's colours.
- **WAC Next's Account** uses it.

## The band and the status bar (fixed 30 October 2026, after Peter's phone)

Peter, on WAC Next 202610301625: "The jobs mast head is not consistent and goes into the safe area and the account screen does not have a masthead."

- **The band takes the top bleed's inset** (`cmsBleed.underTop`), as a top-bleeding card does. Before, a page's band ignored it, and Jobs' title sat in the status bar.
- **Its text is the site's font** (`theme.font`), as cards use. A leading band has one title line. A centred band starts its text right under the bars, as WAC's record masthead does.
- **`pinKeep: 0` is kept on iPhone.** The decoder used to drop 0, so nothing ever cut what scrolls at the status bar. A page's masthead now carries `pinKeep: 0`, and WAC's Home header has it too.
- **One height on a `wac` band:** the status bar, then 24, one 32-point title line, 24, and the 24 cut-in, WAC's `SettingsMastheadView`. Jobs and Account measure the same: the title at about 107 points and the first card at about 155.
- **Screenshots** (iPhone 17 Pro Max, iOS 27, user 64) are in `docs/plans/cms-masthead-screens/`: `before-*` and `after-*` of the four tabs, a page-form, and scrolling.

## Over or under

`under` (on a masthead style, a page's masthead, a form's `mastheadScroll`, or `cmsSiteMasthead(scroll:cut:)`) cuts what scrolls at the cut-in line, as WAC's screens do. The rules and WAC's settings are in the web doc's "Over or under".
- **Pinned pages:** `frame.pinUnder` moves `CmsPinnedListClip`'s line to the cover line. `CmsBelowLine` keeps rounded top corners at the cards' inset.
- **Page-forms and host screens:** `CmsMastheadChrome` masks the list at the line in screen points (`safeTop + bandHeight - overlap`). It's a fixed shape: the list scrolls beneath it, with nothing worked out per frame.
- **`pinKeep` and `pinUnder`** both decode on the iPhone. `pinKeep: 0` is kept, and `pinUnder` takes `rounded` or `straight`.

## The viewer's switch

- **The `deviceSetting` block** is a menu `Picker` row, shown when the theme allows the choice.
- **`CmsFormPresentationSetting(cmsId:)`** is the same choice as one row for a host app's own settings screen. WAC Next's Account has it under "On this iPhone".
- **Where it's kept:** both write `UserDefaults` under the web's key, through `@AppStorage`.

## Tests and the check

- `swift test --filter CmsMastheadTests` runs the shared cases (styles, pages, presentation), checks that the page transform runs once and hides the title, and checks that a form's `presentation`, `masthead: false` and `subtitle` decode and encode.
- In WAC Next on an iOS 27.1 simulator (iPhone Duo), 30 October 2026: see the web doc's "Checked".
- In the Playground, on the same simulator:
  - The shop's Return a product slid in as a page under the gradient `metric` band.
  - Swiping back returned to the Forms page.
  - Expense claim opened as a sheet (the theme's default).
  - Book a stay opened as a page with "Which room?" in the band. The room list pushed, and Continue pushed "When are you staying?" (Step 2 of 3 · Dates).
  - Swiping back returned to step 1, and Back with changes asked before it discarded.

## Limits

- **The first card's position** counts a grouped list's own top margin as about 20 points.
- **Swiping back is off while a page-form has changes,** as a sheet's swipe is.
