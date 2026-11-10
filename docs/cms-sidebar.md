# A sidebar like WAC's, on iPhone

The iPhone half of `docs/plans/cms-sidebar.md` (Peter, 28 October 2026: "extend or create new CMS components that can be configured to behave like the WAC sidebar, but it needs to be extensible and configurable"). WAC's sidebar is `RecordMenu`. Here it is built from general pieces, and WAC's Records is one configuration of them. The web half and the shared shapes are in `chrome-extension/packages/shared-types/src/cmsSidebar.ts`.

## The pieces

| Piece | Where | What iPhone does |
|---|---|---|
| `listSelector`, natively | `CmsListSelectorBlock.swift` (`CmsChoiceList`, `CmsChoiceOption`) | A choice list drawn in the sidebar's idiom: clean rows, 40 tall. It is described in the next section. |
| A section's `headerAction` | `CmsSectionBlockView` | A button in the heading's row, after the heading. `look: 'pill'` is a `primary` capsule with its label in paper; otherwise it is plain words in `primary`. The button carries the action button's fields. |
| `frame.pin: 'bottom'` in a side region | `CmsDrawerOverlay.splitPinnedBottom` | The drawer draws the region's other blocks in its scroll view, and the pinned ones at its foot, under a divider (WAC's profile row), as the scroll view's bottom inset, so the last rows scroll clear of them. Outside a side region it does nothing. |
| `actionType: 'openSidebar'` (`edge`) | `CmsRuntime.openSidebar(edge:)` | Opens the current page's side region on that edge (`left` by default) as the drawer, as the edge swipe does. It works on the action button, button menu rows and embedded actions. A card uses `open: { sidebar: 'left' \| 'right' }`. With no region on that edge, nothing happens. |
| The calendar's `headerActions` | `CmsSimpleCalendarBlockView.gridHeader` | Icon buttons in the month row: `leading` ones before the month, `trailing` ones after the arrows. They take the calendar surface's text colour (WAC's ☰). |
| `sidebarWidth` | the sidebar layout (`blocks.sidebarWidth`, or `leftSidebarWidth`/`rightSidebarWidth` beside it) | The drawer's width for that side, capped to the screen less 48. WAC's is 321. |
| `mobileBurgers: 'none'` on a page | `applyPageContext` | No ☰ bar for the side regions (the page opens them from its own button). The edge swipe stays. |

**Embedded actions.** A choice list's row action and add row, a section's header button and a calendar's header buttons are each drawn by `CmsActionButtonBlockView` with a smaller `chrome` (`.icon`, `.pill`, `.plain`, `.row`). Their action is the button's own code: confirmation, the input sheet, a failure alert, and `placeholder: true` ("<label> is coming soon").

## The choice list

- **Options:**
  - `options: [{ value?, label, media?: { symbol | image }, color?, predicate?: { operator }, placeholder? }]`, which win over `manualOptions` (still read when `options` is unset). An option with neither a value nor a predicate takes its label as its value. A predicate operator that isn't a range operator makes no period.
  - From a query: `valueColumn`, `labelColumn`, `colorColumn` and `imageColumn`. `image: { chain }` is a list row picture's chain; without it, the column holds an address. A value seen before is left out.
- **Looks:**
  - `look: 'highlight'`: the chosen row on the glass lozenge in `primary`, with a semibold label.
  - `look: 'check'`: tick boxes in each option's colour (a palette role or a CSS colour, else `primary`), filled with a tick when chosen.
  - Unset, as before: tick boxes when choosing several, else a trailing tick.
- **Choosing:**
  - Pick one: a second tap clears it, as on the web, unless `minSelected` is at least 1 or the look is `highlight`.
  - Pick several: the last options can't be unticked below `minSelected`.
  - `defaultSelection` (`'all'`, `'first'` or values) is applied once, when the options arrive, and never picks a placeholder or a period.
- **Immediate:** a tap changes the tick or the lozenge at once, with no animation, as the finger lifts.
- **Periods:** a period option writes the shared `datePredicate` parameter named by the list's `parameterId`, the one the calendar writes: `{ operator, start, end }`, with ISO dates only for `between`, which asks for them in a sheet first. The list's highlight follows that parameter, so a period picked on the calendar shows in the list.
- **Output:** the web's exactly: `value` is the chosen real values comma-joined, `count` how many, and nothing is published when none is chosen. A period is not a value.
- **One choice for every copy of the list:** the choice is kept in the runtime by the list's slug (`listChoices`), not in the view. A side region is also mounted offstage on its page (`CmsSidebarLayoutView`), so its lists publish their defaults when the page loads, not only once the drawer opens. The drawer's copy shows and keeps the same choice.

**The calendar follows the shared parameter.** When another block (a sidebar's period list) writes the calendar's `parameterId`, the calendar takes it: its state, its predicate line ("This week · 26 Oct – 1 Nov") and its own output. Its own write comes back equal and changes nothing. The web's calendar already reads the parameter as its state.

**The drawer covers the tab bar** in `CmsAppView`, as WAC's does. The overlay sits on the tab view, not inside each tab.

## On a sidebar page, the page's levers read the main region

- **Main region:** `CmsLevers.firstBlock` reads `slots.main`, and `floatingButton` searches `main` before the side regions. A pinned or bleeding first block, `pinCover`, `pinKeep`, `overlap` and the floating + work on a sidebar page exactly as on a plain page.
- **Drawer:** on a phone the main region fills the screen and the side region is the drawer.

## Opening the drawer by the edge

- **Tab roots claim the edges:** in `CmsAppView`, a tab's root page now claims the screen edges (`edgeSwipeEnabled: isRoot`). A pushed page keeps the edge for its back swipe. The strip shows only when the page has a side region.
- **A window pan as well:** the page's 22-point edge strip lost the drag wherever scrolling content lay under the edge (Records' full-width sheet, a bleeding block), because the scroll view took it. So the sidebar layout also puts a pan on the window (`CmsSidebarEdgePan`).
  - It begins only for a sideways drag that starts within 22 points of an edge with a region and moves inward (`CmsEdgeDrag`).
  - Scroll views' pans wait for it, and it fails at once anywhere else.
  - It slides the drawer in under the finger, as the strip does.
- **One owner per registration:** a sidebar layout releases its edge registration only if it is still the owner (`edgeSwipeLeftOwner`). A copy replaced as the page first loaded used to clear its successor's equal slot as it disappeared, which left the ☰ and the swipe with nothing to open.
- **The calendar's swipe:** its pan answers through a delegate object, not UIView's own `gestureRecognizerShouldBegin`, which UIKit also asks about other gestures.

## Following the finger

Peter, 29 October 2026, on his iPhone 17 Pro Max: "the tracking is much better in WAC, it needs to feel like it's glued to your finger as you swipe in. Ours is janky and jerky and possibly burning CPU as well."

- **The cause:** the drawer's offset was `@Published` on the runtime (`drawerOpenOffset`), and the edge strip kept `@State` too. Every touch therefore re-rendered every view that observes the runtime, which is the whole page.
- **Now UIKit places it** (`CmsDrawerTrack.swift`):
  - `CmsDrawerOverlay` hosts the panel's SwiftUI content once, in a `UIHostingController` inside `CmsDrawerTrackController`. It hands over the page's environment (`.environment(\.self, …)`) with the runtime inside it.
  - A pan sets the panel's `transform` and the scrim's `alpha` directly (`CmsDrawerTrack.drag`). SwiftUI hears only that a drawer opened (`openDrawer`) and, once it has reached its edge, that it closed (`finishClosingDrawer`, which runs the request's `onDismiss`).
  - The runtime's entry points are `beginInteractiveDrawer`, `dragDrawer`, `releaseDrawer` and `closeDrawer`. A test checks that a drag publishes nothing.
- **Release:** a `UIViewPropertyAnimator` spring (damping 0.9, 0.42 s), starting at the finger's speed. It opens when the position, thrown on by a fifth of a second at that speed, is past halfway (`settlesOpen`). A new drag stops a spring where it is (`grab`), so the spring can be interrupted.
- **Opening:** the system's screen-edge pans (`UIScreenEdgePanGestureRecognizer`, left and right) were added on the window beside the 22-point pan. WAC's `RecordMenu` uses the screen-edge pan, and a finger on the very edge opens it.
  - Measured in WAC Dev: a swipe from 2 points opened it, but swipes from 10 and 20 points, from mid-screen, or on Home did not. So WAC opens from the edge only, and only on Records. Ours opens from the edge on a page with a side region, which matches.
  - Before this change, our plain pan missed a swipe that began on the very edge: it didn't open from 2 or 8 points with the Mac's simulator input, only from 16.
- **Closing:** a sideways drag toward the edge, on the panel or the scrim, moves it the same way and springs. A vertical drag is left to the panel's scroll view, which waits for the sideways drag to fail. A tap on the scrim closes it, and so does `closeDrawer()`, from wherever it is.
- **macOS** keeps a plain SwiftUI scrim and panel.

**Measured** (29 October 2026). The input was the Mac's simulator touch, the same for both apps (`screenWindows.simulatorInput` through the host, a 0.8 s swipe across 75% of the screen). The measure was `device_layer_animations` `trace`. Ours was the stand-in Records page on an iPhone 17 Pro simulator (iOS 26.4); WAC Dev's Records was on simulator 6983CB27 (iOS 27.0).

| | Ours before | Ours after | WAC Dev |
|---|---|---|---|
| Frame rate during the trace | 51.9 fps | 58.6 fps | 58.2 fps |
| Gaps over 33 ms while dragging | 13 (79–129 ms) | 0 | 0 |
| Freezes mid-drag | 4 (89–129 ms) | 0 | 0 |
| Main thread awake | 20.5% | 9.8% | 9.9% |
| Longest main-thread wake | 382 ms | 83 ms (building the panel, at the start) | 97 ms (465 ms on the first open after a launch) |
| Positions over the drag | 21, one jump back | 53, evenly spaced at the finger's 0.33–0.37 pt/ms | 52, at the finger's speed |

After the change, the ☰ opens it in 283 ms, and a tap on the scrim closes it in 233 ms (16 even frames). Both were checked in light and dark, and a row in the drawer still takes its tap.

## Tests and the check

- **Tests:** `CmsSidebarTests` has 13 tests, covering:
  - written and query options;
  - defaults, toggles and the minimum;
  - the output and the date parameter;
  - the pinned foot and `mobileBurgers`;
  - the layout's widths, kept when stored;
  - the main region's levers;
  - the edge drag's start;
  - a card's `open.sidebar` and `openSidebar` on the runtime;
  - the drawer track: a release by position and speed, a drag that publishes nothing, and closing without a view.

  ```bash
  swift test --filter CmsSidebarTests
  ```
- **Simulator** (iPhone 17 Pro, iOS 26.4): `CmsAppView` with a tab bar, against the local stand-in. Records is a sidebar page. Its main region is the pinned calendar (bleed, `pin: 'behind'`, overlap 48, the sheet, the kept strip) with a ☰ in its month row, a card showing what the sidebar writes, the weeks grid and the floating +. The left region holds:
  - Calendar, with Share as a pill and the periods as a highlight list on a parameter;
  - Jobs, from a query: ticks in each job's colour, `minSelected: 1`, all ticked at first, an edit pencil and Add job;
  - Status, with ticks in `primary`, `tint` and `warning`;
  - a profile card pinned to the foot.

  In light and dark:
  - The defaults were published at load ("Jobs: 7,9 (2)", all three statuses).
  - The ☰ and the edge swipe each opened the 321-wide drawer.
  - Week moved the highlight, through the parameter.
  - Unticking Costa wrote "Jobs: 7 (1)", and Corner Shop then stayed ticked.
  - Records' pinned calendar, sheet and floating + were as before.
  - After the fixes: a screenshot straight after a tap showed the new tick and the new highlight. The drawer covered the tab bar. Pending approval sat clear of the profile row. With Week chosen in the drawer, the calendar read "This week · 26 Oct 2026 – 1 Nov 2026".

## Limits

- **Other tabs:** the edge swipe opens only the current page's regions, not Records' sidebar from another tab (a shell-level sidebar is for later).
- **The calendar's own view** doesn't yet follow the period chosen in the list (a week strip for Week).
- **Choosing a period** moves the calendar only when the calendar has the same `parameterId`.
