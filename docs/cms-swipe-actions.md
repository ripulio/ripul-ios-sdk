# Swipe actions on iPhone

The shape, the rules and the web's half are in `chrome-extension/docs/architecture/cmsListStyles.md` ("Swipe actions"). The iPhone follows the same rules, held to `cmsSwipe.cases.json` by `CmsSwipeTests`.

| File | What it holds |
|---|---|
| `Sessions/GlassSwipeList.swift` | The shared swipe vocabulary (`GlassSwipeAction`, `GlassSwipeSet`, `glassSwipeActions`) and `GlassSwipeList`, a `List` of rows of any height that sizes itself to its rows |
| `Sessions/GlassComponents.swift` | `GlassListSection` takes `swipeActions:` through the same modifier |
| `CmsRender/CmsSwipe.swift` | The rules (`CmsSwipe.resolve`), icons (a nav key, else an SF Symbol name) and the conversion to a `GlassSwipeSet` |
| `CmsRender/CmsRowActionRunner.swift` | Runs an action for a grid list row or a link list row: the inputs from the row, the asked form, the confirm (the action's, else the mutation's), the success note and the failure |
| `CmsCardsBlock.swift`, `CmsListStyleViews.swift`, `CmsAgGridBlock.swift`, `CmsLinkListBlock.swift` | Where cards, list style rows, the grid's phone list and link list rows take them |

## Native-first: the system's swipe actions

- **Only a `List` row has `.swipeActions`.** A CMS page scrolls itself, though, and a `List` inside a `ScrollView` has no height. So rows that swipe are drawn in `GlassSwipeList`:
  - a plain `List` with scrolling off;
  - each row measured (`onGeometryChange`), the list framed at exactly their total plus the gaps;
  - `listRowSpacing` for a card style's gap.
- **No gesture of our own.** Every list in the app shares one base and none rolls its own drag in a row (the list rule). `GlassListSection`, the base for Files, Dock and the other screens, draws uniform 44-point rows in a titled panel and can't hold cards, so `GlassSwipeList` is its sibling. Both use one swipe vocabulary (`GlassSwipeSet` and `glassSwipeActions`), and `GlassListSection` now takes `swipeActions:` too.
- **Each action is a `Button` tinted with its palette role,** in its set's order: the first at the row's edge, and the one a full swipe runs.
  - A destructive action isn't given the system's destructive role, which removes the row at once. The action may ask first, and the refetched rows remove it.
- **VoiceOver:** every action is also an accessibility action (`accessibilityActions`), trailing set first, so nothing needs a swipe.

## Where rows swipe

- **List style rows** (`CmsStyledRows`): a swipe set for any row turns the rows into a `GlassSwipeList`.
  - `cards`: each row its own card, `gap` apart.
  - `system`: one rounded group with separators, the group's card around the list.
  - `plain`: edge-to-edge rows.
  - Each row is opaque, so it covers the buttons until it slides.
  - The grid's phone list and link lists draw through it. A grid with `swipeActions` always uses the styled list, never the bare one.
- **Cards** (`CmsCardsBlock`): a stack whose cards swipe is a `GlassSwipeList` with a card per row; a first display is a list of one.
  - A carousel never swipes, because it swipes between cards.
  - A group's cards don't swipe.
  - A card's action runs as its buttons do: the asked form, a confirm, the pending variant, the refetch.
- **Confirm text:** a card button's confirm now names its button ("Archive", "Delete"), not "Run".

## Limits

- **Holiday and sick rows** in WAC's Records don't swipe: deleting one needs its block's id, which the list's rows don't carry. Their form's Delete does it.
- **A full swipe** is per set, not per row: a set's first action runs on a full swipe for every row it shows on.
- **The list's height** counts a row not yet measured as 60 points, for its first frame.
