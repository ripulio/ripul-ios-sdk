# Page and block levers on iPhone

The iPhone half of `docs/plans/cms-home-records-levers.md`, approved by Peter on 28 October 2026 with "Yes", and again with "make sure these are all good useful additions to the blocks etc and not overfitting for WAC".

There are six small levers, and two more from the addendum (overlap and pinned behind, below). Any site can use them; WAC uses them only through configuration. The shared pieces are in `CmsRender/CmsLevers.swift`.

| Lever | Where | What iPhone does |
|---|---|---|
| `titleDisplay: 'hidden'` on a page | `CmsPageBody` (`CmsPageTitleDisplay`) | No navigation title. A root page hides its bar (no large title, and nothing at the top of the scroll). A pushed page (`\.isPresented`) keeps an inline bar for its back button, with no title. It works inside `CmsAppView`'s tab stacks. |
| `bleed: true` in a block's frame | `CmsBleedModifier` (on every block), `CmsBlockFrameModifier`, the card face, the calendar | The page's side margin (`\.cmsPageMargin`, 16 pt) is given back. As the first block of a title-hidden page, the block also runs up under the status bar. The room it needs there (`underTop`) goes to whichever surface draws: the frame's own fill when it has one, otherwise the block's (a card, a calendar). That keeps the content below the status bar. |
| Calendar `surface: { fill, text, muted }` | `CmsSimpleCalendarBlockView` | `fill` goes behind the whole calendar, header included. `text` colours the day numbers, the month title, the arrows and the mode toggle. `muted` colours the weekday letters, other months' days and the predicate line ("Pick a date"). The selection, pills and markers keep their own colours, and an authored typography colour still wins. |
| `groupDefaultExpanded` on a grid | `CmsAgGridBlockView` | The iPhone list has one level of groups, so any value except 0 opens every group (-1 means all; n ≥ 1 reaches the one level there is). Groups the viewer opens or closes stay that way until the rows reload. When the setting is unset, behaviour is as before. |
| `placement: 'floating'` (and `icon`) on the action button | `CmsPageBody`'s overlay, `CmsActionButtonBlockView` | Round and 56 pt, in the theme's `accent`, with the icon (a nav icon key, else +) in `paper` and a soft shadow. It sits bottom trailing, 16 pt from the edges, inside the safe area, so it stays above the tab bar, the iOS 26 minimizing bar included. Its label is its accessible name. The page's bottom content margin grows by 72 pt, so it never covers the last row. Its action is unchanged: confirmation, input sheet, result. Only the page's first floating button is drawn. |
| `{today}` and `{timeOfDay}` | `CmsListRowLayout.slotText`, `CmsLevers.builtIn` | They work in every `{column}` slot: list rows, cards, group headers, and written cards without a query. `{today}` is the viewer's day, formatted with the slot's own `\|` format (unset: `d MMM yyyy`). `{timeOfDay}` is "morning" before 12:00, "afternoon" before 18:00, else "evening", on the viewer's clock. A row's own column of the same name wins. |

## Overlap and pinned behind (the addendum)

Peter, 28 October 2026: the Home cards should cut into a bigger masthead as they scroll, with no shrinking masthead. These are the common "hero you scroll over" pattern, for any site.

| Lever | Where | What iPhone does |
|---|---|---|
| `overlap: N` in a block's frame | `CmsOverlapModifier`, `CmsBlockFrameModifier`, the card face, the calendar | The block's surface grows by N points at its bottom (`\.cmsOverlap`), and the block gives back N plus the stack's gap (`\.cmsStackGap`). So the next block's top sits exactly N above the surface's bottom, drawn over it, and the block's own content is never covered. What grows is the frame's fill when it has one, else the face of a cards block (its last card in a stack, the card on show) or a calendar's fill. Any other block grows its frame, transparent (`CmsLevers.overlapGrowsSurface`). |
| `pin: 'behind'` in a block's frame | `CmsPageBody`, `CmsPinnedPlaceModifier`, `CmsLevers.pinnedBlock` | Only for the page's first block (by `firstBlock`'s rule). The page draws the real block in a `ZStack` behind its scroll view, fixed. In the scroll content an invisible copy holds its place (no taps, hidden from VoiceOver), and the content's background is clear, so the block shows until the cards cover it. It never shrinks, fades or stretches, because it isn't in the scroll view. With `bleed` it sits under the status bar, as the first block would. Any other block with `pin` scrolls normally. |

### A pinned block the page slides over as a sheet (addendum 2)

Peter, 28 October 2026: like WAC's Records, the calendar stays where it is and the records rise over it as one sheet, keeping the month row. These settings apply to the pinned block, and any site can use them: a map with a list sliding over it, or a profile header that keeps its name row.

- **The pinned block takes taps** (it replaces "its buttons can't be pressed"). `CmsPinnedLayers` draws the real block inside the scroll content, beneath the page's list, and moves it by the scroll (`CmsScrollTracker`, read from the scroll view's offset), so it stays put. Its days, arrows and buttons work wherever the list leaves it uncovered, and anything that covers it takes the tap. The real block is drawn with the gap of the list it holds a place in (`cmsStackGap`), so its overlap gives back N plus that gap, exactly as it would in the list. Until this fix it was drawn with no gap, and what followed started a gap lower: on Home that showed 28 points of the masthead instead of 44. Its place in the list is an empty frame the real block's height (`CmsPinnedHeightKey`, measured where it is drawn), so the page makes room whenever the block grows or shrinks: a month with six weeks, a selection line, Dynamic Type. The place also reports where the content starts and the surface ends (`CmsPinnedGeometry`). It used to be an invisible copy of the block, but the copy kept its own state, such as its own month, and so its own height. Only two small modifiers read the scroll, so scrolling doesn't redraw the page's blocks.
- **`pinCover: 'sheet'`:** the list is laid on one sheet of the page's background (the palette's `background`, otherwise the system background). The sheet starts at the bottom of the pinned surface, overlap included, so an overlapping card sits half on the block. It runs to the end of the page and a screen beyond, and its corners are square. Unset (`clear`) is as before.
- **`pinKeep: K`:** the list (and its sheet) is clipped K points below the top of the block's content. With a top bleed that is the line under the status bar's area; otherwise it is the block's top. The strip above is never covered, and taps there reach the block. The clip cuts only the drawing: a clip doesn't stop taps, so rows hidden under the strip still opened. So the list takes taps only below both the kept line and the top of what follows the pinned block (`CmsPinnedListClip`). That limit is a content shape, which starts no higher than the top of what follows, so the list's empty space never catches taps meant for the block's uncovered part. Above that line there is only the block and the overlap's empty surface. A clear pin with no strip leaves taps to the list's own shapes.
- **K for the calendar's month row is 44, agreed with the web (plan, `22368dbef`).** On iPhone the month row ends at 42 (12 of padding inside the fill, plus the 30-point header row), and on the web at 41. 44 covers both and stops before the weekday letters.
- **A calendar on a scrolling page, pinned or not, splits drags as iOS does.** A drag that starts mostly sideways pages the week or month. One that starts mostly vertical scrolls the page, and taps are unchanged.
  - Since 30 October 2026 the calendar's pages are a paging `UIScrollView` (`CmsCalendarPager`, "Paging" in `cms-calendar-day-styles.md`), nested in the page's scroll view as UIKit nests a horizontal shelf. Its pan begins only for a sideways drag, and a pinned block's covered part never reaches it, because the list over it takes those touches.
  - Before that it was a `UIPanGestureRecognizer` on the enclosing scroll view (`CmsHorizontalSwipe`, kept for its tests), with `CmsPinnedCover` limiting it to the uncovered part.
  - The web does the same: `touch-action: pan-y`, with the direction locked after 8 px by the larger axis.
- **The pinned block's height reaches its place in the list through state** (`CmsPinnedHeightReport`: `onGeometryChange`, then a preference). A `GeometryReader` preference kept its first value on iOS 27 when the block was first laid out narrow (a tab appearing) and then at full width, so what followed sat 116 points too low. Once known, changes to the place and the sheet's top ease `.snappy`, so they move with a block whose height eases (a calendar switching to its slim row). While a block's height follows a gesture (a calendar's swipe between months of other rows; it sets `CmsPinnedLiveResize`), each height is taken at once. The place observes its height as an object (`CmsPinnedPlaceHeight`) and the cover is held until the gesture ends: an environment value that changed every frame updated the traits of every UIKit view below it, doubling the main thread's time.
- **A grid under a pinned block needs `nativeScroll: 'page'`.** By default a grid's list scrolls inside its own 400-point box, so the page doesn't scroll over the pinned block.

### A button that opens a glass menu (addendum 3)

Peter, 28 October 2026: "The button needs to drive a pop out glass menu, again configurable not tied to WAC but configured for what WAC does." `menu` on the action button block works for any action button, inline or floating. WAC's Records + is one configuration of it. The code is in `CmsButtonMenu.swift` and `CmsActionButtonBlock.swift`, modelled on WAC's own `AddRecordMenuView`.

- **Opening:** with a menu, the button opens the menu instead of running its action. The menu draws in a clear full-screen cover, as WAC's does, with no slide, so its backdrop covers the page and the tab bar. The backdrop is black at 12%, and a tap on it closes the menu.
- **Floating:** the rows rise from the bottom trailing corner above the button. On iOS 26 each row is its own Liquid Glass element in one `GlassEffectContainer`, appearing with `.bouncy(duration: 0.5, extraBounce: 0.16)` and closing with `.smooth(duration: 0.28)`. Before iOS 26 the rows sit in one material panel that grows from the corner.
  - The glass is regular, not clear, so the words read over a brand-coloured header.
  - The glass isn't `.interactive()`: interactive glass took the touch, and the row's button never fired.
- **Inline:** a panel just below the button, or above it when the space below is too short and the space above isn't. It is Liquid Glass on iOS 26 and a material before.
- **A row:**
  - the label and an optional subtitle;
  - `media`, in a 40-point circle at the trailing end. `symbol` takes a nav icon key or an SF Symbol name. `image` is an address, drawn as it is.
  - `fill`, a palette role for the circle. Unset is a faint tint of the text colour, with the symbol in the primary colour, as on the web. Set, the symbol takes the fill's contrast colour. An image draws at about 62% of the circle.
  - `symbol` should be a nav icon key on a site the web also shows (the web reads only keys). An SF Symbol name works on iPhone alone.
  - The row's action is in the button's own fields, run by the button's own code, confirm and input sheet included. `pageSlug` reads as `targetPageSlug`.
- **`placeholder: true`:** a tap closes the menu and shows "<label> is coming soon". On a floating button the note is a small capsule above the button; on an inline button it is a line under it.
- **`primary`:** the button's own action as the bottom row. The menu's copy of the button stays where the button is, with `primary.label` and `subtitle` beside it, and a tap runs the action. Without `primary`, the button only opens and closes the menu, and its icon turns to a close mark. In that case it needs no action of its own, so it shows no "No mutation selected" note.
- **`style: 'panel'` (the default since the revision; WAC's shipped `AddRecordMenuPopover`):**
  - **The panel:** one glass panel (Liquid Glass on iOS 26, a material before), corners 24 and padding 14, sized to its rows: rows 250 wide, so the panel is 278 (`CmsButtonMenu.panelFrame`).
  - **Floating:** its trailing edge sits on the button's, 14 above it and kept 16 from the screen's sides. It morphs out of a circle tucked inside the button (`collapsedFrame`), frame and corners together, with a spring (bounce 0.26, WAC's damping 0.74), and the rows fade in. The backdrop is black at 16%.
  - **Rows:** solid `paper` cards, corners 14 with a soft shadow, 50 tall and 10 apart. The title is semibold 16, the subtitle 13 in the muted text colour.
  - **`primary`:** the last row, 16 below the others, is a capsule 62 tall in `primary.fill` (unset is `primary`). Its title (bold 17) and subtitle (13) are in `paper`, with the button's icon in a 32 circle of `paper` at 22%.
  - **The button while the menu is open:** drawn where it is, in its own colours, its + turned 45° to a close mark (another icon swaps to ×), with or without `primary`. A tap on it closes the menu.
  - **Icons:** `menu.tint`, a palette role (unset is `primary`), colours every symbol. `menu.tile: 'square'` (the default) is a 32 tile with corners 9, in the tint at 12% (or the row's `fill`), its icon 18. `'circle'` is the 40 circle. Images draw as they are, at the icon's size.
  - **Inline:** the same panel, growing from the button, below it or above.
  - **`style: 'rows'`** keeps the first build: each row its own glass, morphing out of the +.
- **Accessibility:** the button keeps its label and has the hint "Opens a menu". Each row is a button named by its label and subtitle, and the escape gesture closes the menu.

**Settled with the web (the plan, `878cba213`):**
- The gap is absorbed, so the visible overlap is N.
- What grows is the surface that spans the block, as for bleed.
- A pinned block is a backdrop: on iPhone it is behind the scroll view, so its buttons can't be pressed.

## Corners of a bleeding block

A block that bleeds is square at all four corners, wherever it is, including the first block under the status bar. There is one rule and no special case for a header, which also matches the straight edge under WAC's purple header. This is the plan's rule (commit `9c15ebbcc`, settled by the coordinator), and the web follows it too. In code it is `CmsBleed.shape(radius:)`.

## Matching the web's settled details

- **`{today|fmt}`** is formatted directly as a date, so a pattern with no y, M, d or H (`{today|EEEE}`) still works. Text in double quotes is literal.
- **The top bleed** reaches the top only when nothing that takes room sits above the block. The tab bar block, a floating action button, a hidden block and a desktop-only block don't count.
- **Narrower surfaces keep their radius:** a bleeding block squares its own surface and any surface that spans its full width (a card, a list's card or group, a calendar fill). A card in a carousel with `peek` (a glimpse of the next card) is narrower, so it keeps its radius.
- **Out-of-flow blocks:** the tab bar block and a floating action button take no place in their list (no gap is left beside them).
- **Calendar surface:** the calendar already has 12 pt of padding inside its fill. On a surface, other months' days are drawn in `muted` at full strength.

## A change to containers

A container with no rounded corners no longer clips its blocks (`CmsClipWhenRounded`). That clip had no visible effect, but it cut off any block that bleeds past the container, and a floating button's shadow. Rounded containers still clip.

## Tests and the check

- **Tests:** `CmsLeversTests` has 15 tests, covering `{today}` across time zones and formats, `{timeOfDay}` across summer time, the built-ins in lines and headers (a row's column wins), decoding the page and frame, overlap and pin (only the first block pins, what grows), pinCover and pinKeep, the kept line, which drags a pager takes, where the list takes taps, a button menu's decoding, symbols, placement and panel geometry, finding the floating button, groups open by default, and the corners of a bleed.
- **Simulator:** an iPhone 17 Pro (iOS 26.4) running `CmsAppView` with a tab bar, against the local stand-in for the CMS routes, in light and dark:
  - **Home:** title hidden, with a toned card bleeding under the status bar as a masthead, showing "Wednesday, 28 October 2026 / Good morning Sam".
  - **Records:** title hidden, with the calendar bleeding on a `primary` surface; the week groups started open, and the + floated above the system tab bar.

- **Overlap and pin:** the masthead page, its greeting card toned, bleeding and pinned with overlap 44, then scrolled 160 points. The masthead stays put under the status bar, and the first card starts 44 points into it, then slides up over it, in light and dark.

- **The pinned sheet:** a title-hidden page with a calendar bleeding on `primary`, pinned with overlap 48, `pinCover: 'sheet'` and `pinKeep: 42` (before 44 was agreed), then a card and a grid. Driven with the SDK's simulator tools, in light and dark:
  - At rest, the card sits half on the purple, with the sheet below.
  - Dragged up, the sheet and the card cover the days, and the month row stays.
  - Scrolled further, the list scrolls on beneath the kept row.
  - A tap on the month arrow while the list lay beneath it moved the calendar to November.
  - Home's clear-pinned masthead is unchanged.
  - **Strip taps and room, as on Records:** the calendar shows its month grid with `pinKeep: 44`.
    - Paging from October (five weeks) to November (six), and back, moved the summary card down and up to make room.
    - With the list scrolled until the grid's search field lay under the ‹ arrow in the strip, a tap there moved the calendar back a month, and the field didn't take focus.
  - **Drags, pinned and unpinned:** a vertical drag starting on the calendar scrolls the page, and a sideways one pages to the next week. On the pinned page, a sideways drag on the summary card over the calendar left the week as it was.

- **Button menu:** on the Records page of the stand-in, the floating + has WAC's six placeholder rows (symbols, one image, `tint` and `accent` fills) and `primary` "Add an entry". On the Cards page, an inline "Export" has two rows. Driven with the SDK's simulator tools, in light and dark:
  - The rows rose out of the +, which grew into "Add an entry".
  - A tap on Holiday closed the menu and showed "Holiday is coming soon".
  - A tap on the backdrop closed the menu.
  - The inline menu opened as a glass panel below Export.
  - **The revision (`panel`),** with WAC's Records menu as configuration (`tint: 'primary'`, nav icon keys, no fills): in light and dark, the panel opened above the button with its trailing edge on the button's, showing paper rows with square tint tiles and the purple "Add an entry" capsule, the + turned to ×. Holiday showed "Holiday is coming soon".
- **The pinned sheet follows a live switch to dark mode:** `CmsPageSheet` observes the runtime. It used to keep the light colour until the page was drawn again.

## Limits

- **Button menu:** the inline panel's height is estimated (56 points a row) to choose below or above. The menu's rows don't scroll, so keep to eight (`button-menu-long`).

- **Pinned, pulling down:** the block moves with the scroll's offset, which keeps it still through a pull too, so it doesn't stretch. This wasn't checked separately.
- **Overlap on a grid:** a grid's card list doesn't grow its own last card; the frame grows, clear.
- **Text over the pinned block:** a section heading that scrolls over it keeps its own colour.

- **Margins:** a bleeding block nested inside a container with its own padding gives back only the page's margin.
- **Calendar:** the slim row's chips keep their own colours on a surface.
