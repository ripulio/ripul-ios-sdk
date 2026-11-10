# Calendar day styles on iPhone

How the native Calendar Strip (`simpleCalendar`) draws a day: the day's shape, a second ring on the same day, how markers look and where they sit, and today and the selection. Also how the month view's grid is drawn (other months' days, how many rows), how its height follows a swipe, and the popover a tap on a day can open (its details). The options are general; WAC's look is one configuration of them.

- **Why:** Peter, 29 October 2026, on WAC Next's Records calendar: "looks nothing like WAC … this is just one style amongst many; ensure the style config has lots of options."
- **The plan:** `docs/plans/cms-calendar-day-styles.md`.
- **The shared shape:** `chrome-extension/packages/shared-types/src/cmsCalendarDayStyles.ts`, with its table of cases `cmsCalendarDayStyles.cases.json`. The web and the iPhone test against the same file.
- **The web side and the earlier props** (`dayFill`'s column and values, `markers`' key, colours and image chain, `legend`): `chrome-extension/docs/architecture/cmsCalendarMarkers.md`.

A site that sets none of these options looks as it did before.

## The options

| Option | Values (default first) | On iPhone |
|---|---|---|
| `dayFill.style` | `filled` · `ring` · `soft` · `underline` · `none` | A solid shape; its outline (2.5 pt); the colour at 20% behind the number; a 3 pt capsule under the number, 45% of the shape's width; nothing. `none` still counts as a fill for `onlyWithFill`. |
| `dayFill.shape` | `circle` · `rounded` · `square` | Radius: half the side, a quarter, none. A rounded square uses continuous corners. |
| `dayFill.size` | `fit` · points | `fit`: the cell's shorter side less 6. A native day cell is the column's width by a 38 pt row, so on a phone `fit` is 32, the size before the option existed. Narrow columns shrink it, to 16 at least. |
| `dayFill.textColor` | `auto` · a colour or token | On a `filled` day. `auto` is black or white by WCAG relative luminance, cut at 0.179 (the web's `dayTextOn`). On a `soft` day an authored colour is used, `auto` keeps the plain number colour. |
| `dayRing` | `column`, `values`, `colorColumn`, `whenSeveral` (`first` · `neutral` · a colour), `width` (2), `gap` (1) | A ring `gap` points outside the shape, `width` thick, concentric with it. `neutral` is the calendar's `surface.text`, else the primary label colour. |
| `markers.look` | `auto` · `dots` · `images` | `dots` never asks for an image. `auto` draws its earlier dot until or unless an image loads. `images` shows only its background and border while the image loads, then the image or its `imageFallback`. |
| `markers.size` | 14 with images, else the block's `dotSize` (8) | The diameter. A dot in an image's slot (`auto` with a chain) is 60% of it, as before. |
| `markers.placement` | `below` · `overlap` · `inside` · `corner` | Under the shape; centred on its bottom edge, with room left under the row; in the shape under the number; a badge centred where the shape's edge meets the diagonal at the top right. |
| `markers.gap` | 2 · points | Points between markers. Negative overlaps them like stacked coins, each drawn over the one before it (left to right), stopped at half a marker (`markerGap`): WAC's logos are 19 with −5. After overlapping markers, the overflow sits 2 points after the last one. |
| `markers.overflow` | `count` · `plus` · `none` | "+n"; an SF Symbols `plus`, heavy, the size of a dot; nothing. |
| `markers.border` | `none` · `{ width, color }` | A ring outside the marker's size (the web's box-shadow), so it takes no room and a later coin's ring lies over the one before. On an image, placeholder, disc or initial; the earlier `auto` dot doesn't take it. |
| `markers.imageShape` | `circle` · `rounded` | Rounded: a quarter of the size, continuous. |
| `markers.onlyWithFill` | `false` · `true` | Markers only on a day that has a `dayFill` value. A day with only a ring keeps the ring and no markers. |
| `markers.imageBackground` | none · a colour or token | Drawn behind an image marker, inside its shape, and as the marker while its image loads. White, for logos with transparent edges. Unset, images sit on the theme's paper colour and a loading marker shows only its ring. |
| `markers.imageFallback` | `placeholder` · `dot` · `initial` | What an `images` marker draws with no image. `placeholder`: a neutral disc (`imageBackground`, else 12% of the text colour). `dot`: a full-size disc in the row's colour. `initial`: that disc with the label's initial, semibold, 55% of the size (7 at least), black or white by the 0.179 luminance cut. `auto` keeps its earlier dot whatever this says, so a site that sets nothing looks as before. |
| `markers.labelColumn` | none · a column | The text that names a marker, for its initial; else the key. With `keyColumn: 'job_id'`, set `labelColumn: 'job'`, or the initial is a digit. The initial is the label's first letter or digit, upper-cased, else its first character (`markerInitial`, the web's rule and its `initials` cases). |
| `markers.iconColumn` | none · a column | The row's icon: a nav icon key (read through `CmsNavIcon.symbol(for:)`) or an SF Symbol name. With no picture, the marker is a disc in its colour with the symbol on it, black or white by the same luminance cut, sized as pictures are; it comes before `imageFallback`. Counts as asking for images (`usesImages`). Ignored with `look: 'dots'`. The web reads it the same way (`cmsCalendarMarkers.md`); test `testAMarkersIcon`. |
| `todayStyle` | `auto` · `bold` · `ring` · `fill` · `dot` | `auto`: bold, plus a 1.5 pt ring in the selection colour when the day has no filled or soft colour and isn't selected. `ring`: that ring on any day not selected. `fill`: the selection colour at 18% on a day with no other fill. `dot`: a 4 pt dot under the number. All of them keep the number bold. |
| `selectionStyle` | `auto` · `ring` · `fill` | `auto`: a filled day keeps its colour and gains a ring outside, any other day fills with the selection colour. `ring`: a 2 pt ring outside the shape (and outside a day ring). `fill`: the selection colour in the shape, with contrasting text. |

Unknown values fall back to their defaults when drawing; `check_site` reports them (the web's `dayStyleIssues`).

**Markers fit their day** (30 October 2026, after Peter saw coins and a "+1" spill into the next day in the Playground app). A day's cell is its column's share whatever it draws (`minWidth: 0`), so nothing in a day widens the grid. One shared rule decides what a day draws in it (`markerScale`, `markersShown`, `markerRowWidth` in `cmsCalendarDayStyles.ts`, here `CmsCalendarDecorations`; the cases file's `markerFit` table holds both renderers to it):
- **The row's width** is the markers `gap` apart, the rings outside the ends (`markers.border`, image markers only), then the overflow, 2 points after coins. The overflow's width is estimated at 0.6 of its font a character: "+n" at max(9, round(size × 0.8)), "+" at max(8, round(dot × 1.6)), the dot 60% of an image marker's size. The iPhone draws the "+" at that size too, as the web did.
- **The width a day has** is its column for `below` and `overlap`, its shape for `inside`; a `corner` badge isn't fitted.
- **The scale:** when `max` markers don't fit a column, every marker of the calendar is drawn smaller, down to three quarters of its size, so markers keep one size across the month.
- **Fewer:** a day whose markers and overflow still don't fit shows one fewer at a time, and the overflow counts the rest.
- WAC's coins (19, gap −5, max 3) keep three at full size in a 440-point phone's 54-point columns and at 0.997 in a 402-point phone's. A fourth job shows two coins and the "+". The playground's instructor coins in a card's 44-point columns draw at 0.9; a day with four classes shows one coin and "+3".

**Rings stack outward.** The shape, then the day ring `gap` points out, then the selection ring. Without a day ring the selection ring sits where it always did, 2.5 to 4.5 points out. Outside a day ring it sits 1 point out and markers below get 2 points more room, so it never clips them. The paging clip leaves room for the outermost ring (`CmsDayLook.ringRoom`).

**The ring's rule** (`CmsCalendarDecorations.decorate`, the web's `dayRingFor`). The first listed value present on the day decides. Of the rows holding it, the first's own valid `colorColumn` colour is used, else the value's colour. "Several" means `colorColumn` is set and those rows hold more than one distinct valid colour, compared trimmed and lower-cased. Then `whenSeveral` replaces it, unless it is `first`.

## How it is drawn

- **Coins.** The markers are an `HStack` whose spacing is `markerGap`, so a negative gap overlaps them, and SwiftUI draws each over the one before it. The overflow sits in an outer stack with its own spacing. Each image is filled into the marker's shape over `imageBackground`, with `border` drawn inside the shape.
- **No flash before a logo.** An `images` marker starts as its `imageBackground` and border, and draws its fallback only when its chain has nothing or every entry fails. WAC's own app does the same (a white coin until the logo arrives), and so does the web. The image cache is per page and asks the image route once per logo and size (`CmsMarkerImageCache`).
- **Agreed with the web** (0f36f233f, 5dcfe950b): the fallbacks for `images` only, the overflow 2 points after coins, the initial's weight and colour, the loading marker, paper behind images, the ring outside the size, no ring on the `auto` dot.
- **One reading per render.** `CmsDayLook` parses the props once for the whole week or month and carries the sizes every cell shares. Before, each of a month's ~42 cells parsed `dayFill` and `markers` on every render, through computed properties.
- **SwiftUI shapes, not layers.** Each part of a day is a `RoundedRectangle`, `Circle` or `Capsule` fill or `strokeBorder`, in overlays on the number's fixed frame, so nothing measures text or changes the layout from day to day. A month swipe moves one view with an identity per month, as before (`pageIdentity`).
- **Colours.** Site colours and tokens go through `runtime.color`; the surface roles (`surface.text`, `surface.muted`) colour the neutral ring, the overflow and placeholders. CmsRender is outside the theme-token check (`check_theme_tokens.py` skips it): its colours are the site's.

## Paging

Peter, 30 October 2026, on WAC Next's Records: "When we scroll a month the job dots appear first, then the dates arrive … If I swipe slowly I just see empty space as the last month's days leave … Swiping the month needs to feel like the surface is connected to my thumb, and icons and days need to be bolted together."

**Before:** one page was drawn. A drag set a SwiftUI offset on every touch, re-rendering the calendar, and the next month didn't exist until the finger lifted. Then the anchor changed and a `.transition(.move)` slid the new month in.

**Now** (`CmsCalendarPager.swift`), on iOS, month and week alike:
- **One view per page.** The month or week shown and its two neighbours are drawn in full: days, fills, rings, markers, today and the selection. Each page is one SwiftUI view, hosted in its own `UIHostingController`, so a page's days and markers can't part.
- **A paging `UIScrollView`.** The surface follows the finger from the first point, settles with UIKit's paging physics, and nothing in SwiftUI changes while it moves.
  - It has no indicators and no vertical scroll, so a vertical drag fails its pan and scrolls the page.
  - Day touches aren't delayed (`delaysContentTouches = false`), and a scroll cancels them, so a swipe never picks a day.
  - A back swipe from the screen's edge keeps priority (`require(toFail:)` on the navigation's pop gesture). The sidebar's window edge pans already make scroll views wait for them.
- **Settling.** Once the scroll is at rest on a neighbour, the three hosts rotate so the page on screen keeps its own view in the middle, the offset goes back to the middle (the same picture, so nothing moves), and only then does the calendar change its anchor (`settle`).
  - The header's title follows. The height has already followed the scroll (see [the month's grid](#the-months-grid)).
  - The selection and the published date window stay as they were, as paging always left them.
- **The header's arrows** scroll the pager to the neighbour with UIKit's animation, then settle the same way.
- **Re-hosting only what changed.** Each page carries a signature: the selection, today, the props, the theme, light or dark, the grid's width, and its own days' decorations. A host already drawing that signature keeps its views, so a settle builds only the new neighbour, off screen.
- **Size.** The pager is laid over a hidden measure. That measure is one row of cells in a measuring form (markers as empty frames of their size), from a fixed week, repeated for the page's weeks (`CmsRepeatedRowsLayout`). Every row of a page is as tall, so SwiftUI measures any month without drawing it, and no hosted page is asked for its size inside SwiftUI's layout.
  - The first version did ask, and a pinned calendar's place in the page's list stayed at the height from a 117-point-wide first layout, 117 points too tall.
  - On iOS 27 that place stayed wrong even so: the page's `GeometryReader` preference kept the narrow layout's height. The page now reports the pinned block's height with `onGeometryChange`, through state (`CmsPinnedHeightReport` in `CmsPageView.swift`). Once the place and the sheet's top are known, their changes ease `.snappy`, as the calendar's height does (`CmsPinnedLayers`).
- **A taller neighbour** (a month with a sixth week) is clipped to the calendar's height, which follows the swipe towards it, so its sixth week opens as it slides in. The line under the grid, the card and the page's sheet move with it, and nothing draws over them (see [the month's grid](#the-months-grid)).
  - The first version let the taller page overhang the grid, which drew November's sixth row over the "On this date" line while it settled (seen on iOS 27). The next eased the height to the new month once the scroll was at rest.
- **No neighbour needs fetching on wac-app:** `my_calendar` returns all the person's shifts, not the selected month's.
- **macOS** draws the page shown, and the arrows move the anchor.

**Measured** (30 October 2026). WAC Next, as test user C, on an iPhone 17 Pro simulator (iOS 26.4), Records with wac-app's calendar. Input was `device_touch` (a 1.2-second slow drag of 280 points, and a 0.15-second fling of 200 points). The measure was `device_layer_animations` `trace`.

| | Before | After |
|---|---|---|
| Slow drag: frame rate | 51.9 fps | 56.8 fps |
| Slow drag: main thread awake | 52.4% | 21% |
| Slow drag: gaps over 33 ms while dragging | 13 | 0 |
| Slow drag: freeze | 117 ms at the lift, the month held under the finger | none while moving; 83 ms of work once it is at rest (October to November, five weeks to six) |
| Fling: frame rate | 51.5 fps | 55.8 fps |
| Fling: main thread awake | 35.9% | 15.6% |
| Fling: freeze | 101 ms after the lift, before the month moved | none; 61 ms once at rest |
| Paging October to September (no height change) | | 58 fps, 52 ms once at rest |

The work once at rest is the new neighbour's page and the block's update, which before happened mid-gesture.

**iOS 27** (30 October 2026, WAC Next as test user C, iPhone 18 Pro simulator, iOS 27.0), after the coordinator saw the card 114 points low there:
- first load on October (five weeks, six-week November beside it): the card sits half on the purple, `pinnedHeight` 328;
- a slow drag to November: during the drag only five rows show. At the settle the sixth row is uncovered as the line, the card and the sheet move down, with no overlap in any frame of the recording;
- settled on November (six weeks), December by the arrow (five) and February 2027 by the arrow (four): the card half on the purple in each.

Also checked on the iOS 26 simulator:
- a still taken mid-drag shows September and October side by side, each day with its marker;
- a tap on a day selects it ("On this date · 10 Sep 2026");
- a vertical drag starting on the calendar scrolls the page (its offset −62 to +22, then back) and doesn't page the month;
- the arrow slides the month on in 270 ms;
- a drag from the screen's left edge opens the sidebar drawer;
- in the scratch harness, the week strips page the same way.

Videos of the slow drag before and after were recorded with `simctl io recordVideo`.

## The month's grid

Peter, 30 October 2026: "WAC does not show the days of the month before. In its current mode the calendar has a stable set of rows, which is a good design option; we want that capability in the control. But we also want a capability like WAC that doesn't show the days of the previous month, changes the number of rows for a five-week month versus a four-week month, and animates between the four and five rows smoothly as you swipe."

| Option | Values (default first) | On iPhone |
|---|---|---|
| `outsideDays` | `show` · `hide` | `show`: the first and last weeks carry the other months' days, dimmed, as before. `hide`: blank cells there. Each is a day cell in its measuring form, hidden: a day's size, so a row of them keeps a row's height, with nothing drawn, loaded or tapped. |
| `monthRows` | `fit` · `six` | `fit`: the weeks the month spans, 4 to 6. `six`: always six; the extra weeks are next month's (dimmed, or blank with `hide`). |

Both apply to the month view; the week view ignores them. wac-app's `shifts_calendar` is `outsideDays: 'hide'` (WAC's months).

**Which weeks a month draws** is the shared rule (`monthGridShape` in `cmsCalendarDayStyles.ts`, here `CmsCalendarPaging.weekStarts`). Both renderers test against the cases file's `monthGrid` table: each case's rows, and the grid's first and last days. With `hide` and weekends not shown, a first or last week whose days of the month all fall at the weekend is left out.

**The height follows the swipe.** With `fit`, a swipe between months of different rows changes the calendar's height with the finger. The change is in proportion to how far the neighbour has come (`CmsCalendarPaging.growth`): halfway from October (five weeks) to November (six), the calendar is half a row taller. November's sixth week opens as it grows, and the line under the grid, the card and the page's sheet move with it. The arrows' scroll moves it the same way.
- **One number changes per frame.** The pager publishes it from `scrollViewDidScroll` (`CmsCalendarGrowth.extra`, rounded to the screen's pixels). Only the sizer's bottom padding reads it (`CmsCalendarGrowing`), so a frame lays the calendar out again without running its body. The calendar holds the model in `@State`, not as an observed object. It no longer reads the whole environment either: the pager gives the pages `context.environment`.
- **No page is laid out again.** Every host is six rows tall from the start, its page aligned to the top, so a frame moves only the scroll view's clip. The row's step comes from the sizer: `CmsRepeatedRowsLayout` keeps the measured row per width in its cache and tells the model.
- **At rest** the growth goes back to 0 in the same update as the new month, which is then as tall as the calendar already is. Nothing moves and nothing eases.
- **Pinned behind the list**, the calendar marks its height as live while the pager moves (`CmsPinnedLiveResize`), and `CmsPinnedLayers` then takes each height at once. Other changes, such as switching to the slim row, still ease `.snappy`.
- **No environment value changes per frame.** At first the place's height and the cover were environment values, so each frame updated the traits of every UIKit view in the calendar's pages and in the list. That doubled the main thread's time (the Time Profiler found 18% of it in `PlatformViewChild.updateValue` → `UIView _updateTraitsIfNeeded…`). Now:
  - the place's height is an object only the place observes (`CmsPinnedPlaceHeight`);
  - the cover is held while a height is live, and caught up when it ends.

**Measured** (30 October 2026). WAC Next as test user C, on an iPhone 18 Pro simulator (iOS 27.0), Records with wac-app's calendar.
- Gestures: `device_touch` slow drags (280 points in 1.2 seconds) and one fling (200 points in 0.15 seconds).
- Measure: `device_layer_animations` `trace`, frame rate and main thread awake.
- The control is the pager before this change (b8c984f62's SDK), whose height eased once the month settled. The middle column is 5255a9913, before the environment fix.

| Slow drag | Before | Height following (5255a9913) | Now (6e0faa2e6) |
|---|---|---|---|
| October to November (5 to 6) | 58.6 fps, 16.5% | 57.8 fps, 36.3% | 58.7 fps, 21.7% |
| November to October (6 to 5) | 57.9 fps, 18.2% | 57.9 fps, 34.6% | 57.7 fps, 20.9% |
| January to February 2027 (5 to 4) | 58.0 fps, 14.8% | 58.0 fps, 36.6% | 57.7 fps, 19.8% |
| February to March 2027 (4 to 5) | 58.3 fps, 15.3% | 57.6 fps, 44.0% | 58.8 fps, 18.1% |
| Gaps over 33 ms while dragging | none (one 30 to 32 ms at a touch's start) | none, but one of 34 ms at February's start | none |
| Once at rest | 50 to 67 ms (50 to 63 ms of work), then the height eased for about 300 ms | 50 ms | 50 ms (47 to 49 ms of work), nothing moves |

- **A fling** from March to February: 56.8 fps with the main thread awake 16.7%. The height follows the deceleration, 250 to 200 points.
- **In step:** the summary card moved 422 to 470 while the calendar grew 250 to 299. On the way back it went 472 to 424 while the calendar shrank 299 to 250, and 373 to 421 against 200 to 250 from February to March.
- **The recordings:** in every frame of each drag, the next month's extra week is cut at the calendar's edge, with the line and the card below it.

## WAC as configuration

The plan's configuration: `dayFill` `filled` in WAC's five status colours, `markers` `look: 'dots'`, `size: 6`, `max: 2`, `overflow: 'plus'`, `placement: 'below'`, `onlyWithFill: true` with the job's colour, and `dayRing` for paydays with `whenSeveral: 'neutral'`.

Found on the simulator, for whoever sets wac-app up:
- **The selection is invisible on WAC's surface without `selectionColor`.** It falls back to the theme's `primary`, the calendar's own fill. White (`#FFFFFF`) reads.
- **`auto` text is black on pending orange (#E67B19) and holiday green (#88E77B)**, by the luminance rule. WAC draws white numbers on its bubbles; `textColor: '#FFFFFF'` gives that.
- **In dark mode, scheduled (#A17AB1) equals WAC's dark `primary`**, so a scheduled bubble vanishes into the surface. WAC's own Records keeps its light look in dark mode.
- **Bubble and ring size:** WAC's payday ring is about 28 points across. `size: 28` with `dayRing.gap: 0` gives a 32-point ring around a 28-point bubble.

### WAC's logos (30 October 2026)

Peter, with WAC Next 202610291840 on his phone and wac-app set to dots: "the calendar just has dots underneath the days to represent a shift, what happened to the circular icons?" WAC's own app draws the job logos (`CustomFSCalendarCell` in WAC_ios_final's `MonthEarningCalendarHandler.swift`):
- up to three job logos, 19 points, round, on white with a 1-point white ring;
- overlapping by 5 points (centre step 14);
- the group centred under the number, its centre 16 points below the number's centre, which is the bottom edge of a 32-point shape (`placement: 'overlap'`, `size: 'fit'`);
- a job with no logo gets its identity icon in its colour;
- on by default since the feature graduated (Settings ▸ Beta Features, `debug.calendarLogosForFewJobs`), and only on days with one to three jobs. Four or more keep the coloured dots and a "+".

As configuration: `look: 'images'`, `size: 19`, `placement: 'overlap'`, `gap: -5`, `max: 3`, `border: { width: 1, color: '#ffffff' }`, `imageBackground: '#ffffff'`, `imageFallback: 'initial'`, `labelColumn: 'job'`, with wac-app's chain `[{ source: 'brand_logos', column: 'job' }]`.

What differs from WAC:
- **A job with no logo** shows its initial on a disc in its colour; WAC shows its identity icon (a symbol tile).
- **Four or more jobs** show three coins and "+1", and the "+1" runs past the day's column. WAC switches to dots there. `overflow: 'none'` keeps the group inside the column; a rule for switching to dots would be a new option.
- **The columns are narrower:** about 49 points against WAC's 57 (the calendar's 12-point padding and 6-point gaps). So three coins, 47 points across, nearly meet the next day's.
- **Logos are filled into the circle;** WAC fits them inside it. They look the same for square logos.

## Tapping a day: its details

A tap on a day can open the day's rows in a popover (`onDayTap`, `dayDetails`; the shape, the defaults and both renderers: `chrome-extension/docs/architecture/cmsCalendarMarkers.md`, "Tapping a day"). Natively:

- **The popover** is the system's, attached to the day's cell (`.popover(item:attachmentAnchor:)`, the cell's rectangle worked out from the column width, the row step and the ring's room) and kept a popover on a phone (`presentationCompactAdaptation(.popover)`). The system draws the arrow, places it above or below, and closes it on a tap outside.
- **Its size is its content's:** up to 370 points wide, 300 at least, and as tall as the rows. A day with more than fits is held to the room there is and scrolls (the content's measured height is the scroll view's ideal height).
- **The rows** are the list style's rows (`CmsStyledRows` and `CmsLayoutRowContent`, as a grid's list rows on iPhone), with the columns' looks from `columns`. A slot's own format (`{total|£#,##0}`) is applied, as the web's. A row with no `rowTap` is drawn as it is, with no chevron.
- **A row without its leading picture** draws its initial in the picture's place (`leadingInitial`, the rule `CmsCalendarDayDetails.initial`, the web's `dayRowInitial` and its cases), in the marker's look, so every row lines up. A grid's list row still takes no space for a missing picture.
- **The value and chip keep their words** in every list row (`CmsLayoutRowContent`'s trailing column keeps its own width, as the web's never shrinks), and the title and lines give way. Before, WAC's "Worked" chip was cut to "W…".
- **A row's tap** opens its record form (`CmsRecordFormRequest(spec:row:)`, so the first variant whose `when` holds) or pushes the page with the row selected. **The add button** opens the add form with `{day}` filled. Each opens after the popover has closed (0.4 seconds), since a sheet can't be presented from a popover that is closing.
- **With `onDayTap: 'both'`** the day is selected (as a plain tap would) and its details open.
- **The rules** (`CmsCalendarDayDetails`: the tap, whether a day opens, the title, "and n more") are tested against the web's cases.

The same round fixed two things the details needed in shared code:
- **A form's choices that don't say `strict`** (`options: { choices }`, as most forms write them) failed to decode, so the iPhone dropped that input from the form. `strict` now defaults to false, as on the web (`CmsColumnOptions`). Forms across sites that lost a menu or inline choice on iPhone now show it.
- **Styled list rows on the web** grow with their lines when drawn as buttons, and cut lines end with an ellipsis (`chrome-extension/src/cms/blocks/listStyle/listStyle.tsx`).

**Checked on a simulator**, 30 October 2026 (iPhone 18 Pro, iOS 27.0, borrowed from Trainyard):
- **WAC Next as test user C:** 26 October opens "Mon 26 Oct" with the Corner Shop shift (9:00 – 15:00, 6h, Assistant Manager, £66.00, Worked) and "Add shift". The shift opens its edit form, loaded. An empty day (15 October) shows only "Add shift", which opens the add form for 09:00–17:00 that day. Nothing was saved.
- **The playground's four calendars:**
  - the hotel's night of 23 October lists four bookings with room photos, prices, dates and "checked out" chips, and a booking opens "Edit a booking" with its status, dates, booking kind and total;
  - the gym's 14 October lists three classes with times, then "and 1 more", and selects the day;
  - the salon's 30 October shows its title, scrolls through six appointments as cards, then "and 8 more", and an appointment opens the timeline page;
  - the events' 14 November shows the market and "Add a note", whose form now asks for its colour.

## Tests

- `Tests/RipulAgentTests/CmsCalendarDayDetailsTests.swift` reads the shared `cmsCalendarDayDetails.cases.json`: resolving the details and the tap, whether a day opens, titles (en_GB, Europe/London) and "and n more".
- `CmsActionFormTests.testChoicesWithoutStrictKeepTheirInput`: an input whose choices don't say `strict` is kept.
- `Tests/RipulAgentTests/CmsCalendarDayStylesTests.swift` reads the shared `cmsCalendarDayStyles.cases.json`:
  - every `resolve` case: the options with their defaults, the gap stopped at half a marker included;
  - every `days` case: each day's fill value, ring (colour, value, several) and shown keys, and the overflow text;
  - every `initials` case: a label to its letter;
  - every `monthGrid` case: `outsideDays` and `monthRows` with their defaults, and each month's weeks, first day and last day;
  - plus a marker's label from `labelColumn` or the key, the shape's radius and `fit`, `auto` text on WAC's colours, and `dots` asking for no images.
- `CmsCalendarPagingTests`: the pages, the settled step, the rotation, the growth towards a neighbour of other rows (none for weeks, stopped at the neighbour's height), and the growth published once per pixel.
- `CmsCalendarDecorationsTests` (the earlier props) still pass unchanged.
- `swift test --filter "CmsCalendar|CmsLevers|CmsSimpleCalendar"` (48 tests).

## Checked on a simulator

29 October 2026, iPhone simulator "WAC local tools proof" (iOS 27.0), borrowed from Trainyard. A scratch app drew `CmsPageView` against a local stub of the CMS routes: WAC's theme, the calendar with WAC's configuration, and October rows with statuses, two and three jobs on a day, and paydays (one job's, and two jobs' on the 16th).
- **WAC's configuration, light and dark:** same-size bubbles in the status colours; grey payday rings in the job's colour; a white ring on the 16th where two jobs pay (black in dark, the surface's text); two dots then "+" on the 7th; no dots on ring-only paydays; today bold. With `selectionColor: '#FFFFFF'`, today's selection ring sits outside its payday ring and clear of the dots.
- **Other configurations:** `soft` + `rounded` with dots `inside`, the legend, today `dot` and `fill` selection; `underline` + `square` with a `corner` badge and today `ring`; `ring` circles with GitHub avatars as `images` in `overlap` with a white `border`, "+1", a teal payday ring 2 points out, and today `fill`.
- **Beside WAC Dev** (com.dev.WAC, test user C, October 2026) on the same simulator: C has no shifts, only Friday paydays for Corner Shop, so the comparison covers the payday rings and today. The rings match in size and colour, and today is bold in both.

**WAC's logos, 30 October 2026**, on the same simulator. The scratch app showed wac-app's coming configuration above, with October rows of one to four jobs. Its stub served the `brand_logos` image route: KFC, Costa Coffee and Pret got real logos, and Corner Shop, Harbour Café and Night Bar got a 404.
- **Light and dark:** coins overlapping left to right; logos on white with a white ring; "C", "H" and "N" on discs in each job's colour; three coins and "+1" on the 8th (the "+1" past the column); no coins on days without a bubble.
- **Each logo was asked for once per launch** by the page's cache.
- **Rings outside each coin** (a29d68b37 onwards), seen on the simulator. The letters' weight and colour then went back to semibold and the 0.179 cut (5dcfe950b), as the stand-in's first pictures show them.
- **Beside WAC Dev:** test user C has no shifts, so I added one worked shift (6 October, Corner Shop) with WAC Dev's shift tool. Its single coin, 19 points with a white ring and centred 16 points below the number, matches the stand-in's. Corner Shop has no logo, so WAC Dev shows the identity icon where the stand-in shows "C". iOS 27 wouldn't let the tools confirm WAC's delete, so that shift is still on test user C (an observation in the repository).

## Limits

- **The web** pages a month when a swipe ends and its height changes at once; only the iPhone follows the finger.
- **Row height** is the shape plus markers; WAC's month rows are about 59 points tall, these about 42 with a day ring. No option sets it.
- **Weekday labels** stay single letters; WAC writes "Mon".
- **The settle's work** (about 50 ms on the simulator's debug build, after the page is at rest) delays the header's title by that much. The height has already moved.
- **A windowed calendar query** (one whose rows are limited to the selected period) shows other months empty, before and after this change: paging doesn't change what is published, and nothing prefetches a neighbour's rows. wac-app's isn't windowed.
- **Event icon badges** are not in this round (the plan's "Not in this round").
- **A day's details** open on a tap only: no long press (WAC's app adds with one), and the popover doesn't grow out of the cell as WAC's peek does.
