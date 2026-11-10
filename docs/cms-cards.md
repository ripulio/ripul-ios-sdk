# Cards and views on iPhone

The iPhone half of `docs/plans/cms-cards.md` (Peter, "Go with your recommendations", 28 October 2026). It covers:
- **Views in the native runtime:** one set of rows built from a base query and its sources, read as the view route streams.
- **The `cards` block, natively.**
- **Card styles** from the theme.
- **The section carousel**, which now pages.

The web half is `chrome-extension/src/cms/blocks/cards/`. The shared shapes are `packages/shared-types/src/cmsCards.ts`, `cmsViews.ts` and `cmsCardStyles.builtin.json`.

## Views in `CmsRuntime`

| File | What it holds |
|---|---|
| `CmsViews.swift` | `CmsViewDef` (decoded leniently: a view missing its slug, base or key is left out, never failing the site), the stream's events (`CmsViewEvent`), and a view's rows with each row's source statuses (`CmsViewResult`) |
| `CmsClient.runView` | `POST /v1/cms-definitions/:id/views/:slug/run` with `Accept: application/x-ndjson`, read with `URLSession.bytes(for:)` line by line. An answer in one piece reads as the same events. |
| `CmsRuntime` | `viewDefs` (set by `CmsPageLoader` from the definition's `views`), `viewResults`, `requestViewRows`, `retryViewRow`, `viewSourceStatus` |

- **A view's slug works wherever a query's does.** `ensureLoaded`, `state(for:)` and the blocks don't know the difference.
- **Parameters:** a view's params are its base query's, resolved as that query's `paramSources` would be.
- **Streaming:**
  - The base line makes the rows: the view's state is `.ok` at once.
  - Each source line adds its row to the matching view row as `alias.column` keys (`estimate.net`). A ready result with `row: null` clears that source's columns.
  - Every update publishes, so blocks redraw as columns arrive.
- **A failed base** answers with its HTTP status (4xx, or 424 for a 5xx) and one JSON error line. The client reads that line's message even on a non-2xx, so the block shows the server's words, not a raw status.
- **With `keys`,** the server sends the base line again and only per-row sources answer. The runtime keeps the rows it has and merges only the sources.
- **Status per row and source:** `pending`, `ready`, `failed(message)` or `later`.
  - A per-row source starts `later` for the keys the base lists in `later`. A matched source is never `later`.
  - When the stream ends, anything still `pending` becomes `failed`.
- **Later rows** are asked for by `keys` (`requestViewRows`) as their cards come into view, 20 at a time from the card that appeared. Only those sources' columns arrive; the rows shown stay.
- **Try again** (`retryViewRow`) asks for that row's key again. If a matched source failed, it refetches the whole view.
- **Refetching:** `invalidate(slug)` also refetches every loaded view whose base or sources read that query. A mutation's `invalidateQueries` naming the view, its base or any source refetches it.

## The `cards` block

| File | What it holds |
|---|---|
| `CmsCards.swift` | The model, decoded leniently: props, items, cards, parts, variants, conditions, actions and buttons. Also the rules: places and groups, variants, date windows, slots and inputs, and closing. |
| `CmsCardsBlock.swift` | The drawing: the block, the card, buttons, the carousel and the system's page dots |
| `CmsCardStyle.swift` | Card styles: built-ins, choosing, merging and resolved colours |

**Arrangement:**
- **`stack`:** cards in the page. A closed card leaves with the system's animation.
- **`carousel`:**
  - Every card of the block is a page of a paged sideways scroll view (`scrollTargetBehavior(.viewAligned)`, one card wide less `peek`).
  - Under it, the system's page dots (`UIPageControl`, in the style's colours) and "2 of 5" beside them, as `indicator` says.
  - The height follows the card on show, or the tallest with `height: tallest`. `autoplayMs` and `loop` work.
- **`first`:** the first place that isn't an error. A query still loading holds it as a loading card (the system's placeholder look).

**The rules,** agreed with the web (its `cardsModel.ts` and tests):

- **Keys:** a card's key is `card:<id>` for a written card and `row:<item index>:<row key>` for a row's card.
- **Closing** remembers the written card's id or the row's key as text, per block.
  - The block is keyed by its slug: `UserDefaults` key `io.ripul.cms.cards.closed.<cmsId>.<blockSlug>`.
  - A `close: { run }` hides the card while the mutation runs. The refetched rows then decide, and a failure brings it back with an alert.
- **Entries:**
  - A written card that reads a `query` takes its first row, and doesn't show when the query has no rows.
  - A rows item draws each row with `card`, or with the template its `cardsBy` column names; a row whose value names none doesn't show.
  - `max` caps the rows, per group when grouped.
- **Groups:**
  - **Places:** each group takes its first row's place.
  - **One row:** a group of exactly one row is a card on its own, with no header.
  - **Several rows:** a group of several rows stays a group, header included, even when only one card shows (no dots then).
  - **All hidden:** a group whose cards are all hidden doesn't show.
  - **Header slots:** the group column, `{<column>_<aggFunc>}` (in that column's format, from `columns`), and `{row_count}`.
  - **Display:** a group shows as `carousel` (the default), `stack` or `first`.
- **Conditions:**
  - Values compare as text.
  - `empty` covers a missing value, null and blank text.
  - Several tests on one column must all hold; a condition with no test means "not empty".
  - `rows` checks whether a query has rows.
- **Variants:**
  - **Which applies:** a variant shown on request (`show`, kept while the row is the same), else the first whose `when` holds. A variant with no `when` shows only on request.
  - **Replacing parts:** a part the variant sets replaces the card's. An empty list, such as `figures: []`, clears it.
  - **While a mutation runs:** a run with `pending` shows that variant meanwhile.
  - **Running a button** clears a variant shown on request.
- **Dates:** `from` and `until` are inclusive, on the viewer's calendar.
- **Slots:**
  - Each slot draws through the list row's line rule: the column's format, words beside an empty value dropped, a line with every slot empty dropped.
  - A slot can carry its own format (`{pay|"£"#,##0.00}`).
  - `@query.column` tokens work too.
  - In `inputs`, a value that is only one slot keeps the column's type (`"{id}"` gives `{ value: 42, type: "integer" }`); any other text is text.
- **Waiting for a written card's `query`** (the plan, `bd2304313`). Before this, WAC Next's Home showed no masthead for its first second and then jumped down, because the greeting reads `me` from Rails and was left out until its rows came.
  - While the query loads, the card holds its place as itself (`queryWaiting`) in every display: stack, carousel and first.
  - Only the query's slots draw as placeholders, inline: the slot's room is filled with the system fill, and the words around it draw at once (`CmsCards.waitingRow` and `waitingSegments`). The card's own text, built-in slots (`{today}`, `{timeOfDay}`), `@query.column` tokens, media and style draw at once too. VoiceOver reads the slot as "loading".
  - A `when` (or a variant's) that reads the query keeps it a placeholder card until the rows arrive.
  - When the rows come: none, and the card goes; otherwise its slots fill in place, with nothing moving.
  - If the query fails, the card shows "Couldn't load this" with Try again (`queryFailed`), and Try again runs the query again.
- **Waiting for a view:**
  - A whole card draws as a placeholder (`.redacted(reason: .placeholder)`) when its or a variant's `when` reads a source still `pending` or `later`, or a `rows` condition's query is still loading.
  - Otherwise each line that reads such a source draws as a placeholder line.
  - "Couldn't load this" with Try again shows when the parts the card draws read a failed source.
- **Buttons:** filled, outlined, tinted or plain, in the style's look, with an optional nav icon.
  - **Inputs:** a mutation's inputs that the card doesn't supply are asked for in `CmsActionInputSheet`.
  - **Confirmation:** a mutation with confirm text asks first, in a system alert.
  - **Failure:** a failure shows in an alert.
- **Opening a page with params:** there are no page parameters. The card's row, with the filled params over it, becomes its query's selection (as a grid's drill), then the page opens. A tab opens its page.
- **Tones:**
  - **Choosing:** a card's `tone`, which can be `"{column}"`, names a tone of the style; a name the style lacks draws no tone.
  - **Colours:** the fill takes the tone's fill. Title, body, value and figure values take its text; eyebrow, lines, figure labels and the close button take its muted colour; buttons take its accent.
  - **A symbol's badge** on a toned card is the tone's text colour at 18%, with the symbol in it, so the symbol reads.
- **Placement:**
  - **Close button:** top right.
  - **Picture across the top:** `media.topHeight` tall, edge to edge.
  - **Leading picture:** `media.size`, in the style's shape.
  - **`media: { image }`** takes the web's three forms:
    - a `{column}` template, filled from the row; an address with slots in it counts as a template;
    - an `http(s)://` address, used as it is, with or without a row (a written card's picture from the site's asset library);
    - otherwise a column name holding an address, or a column with a picture of its own.

    `chain`, with a row, comes first. This is `CmsCards.mediaCandidates`.
  - **Date:** the list row's date block.

**Pieces shared with list rows:**
- Lines, chips (rules, icons, variants) and inline pictures from image chains are `CmsListRowLayout` and `CmsColumnPresentation`.
- They are drawn in the card style's `lines`, `chip` and `inlineImage`, so a chip looks the same in a list and on a card.
- Text scales with Dynamic Type relative to a text style, and is the style's size at the default.

## Card styles

- **Theme fields:** `cardStyles` and `defaultCardStyle` on `CmsPortalThemeConfig`.
- **Choosing a style:** the block's `cardStyle`, else the theme's default, else `elevated`. A name that names no style is passed over.
- **Built-ins:** `plain`, `elevated` and `outlined` differ only in their surface. They are the shared table; `CmsCardsTests` decodes `cmsCardStyles.builtin.json` and compares.
- **A site style's merge** is the web's `resolveCardStyle`:
  - over its `base`, at any depth, keeping a value only where the base has one of the same kind;
  - a colour that isn't a palette role, an unknown media shape, or an unknown chip variant keeps the base's;
  - a key named like a built-in is ignored;
  - tones merge by name, and a new tone starts from paper, text, mutedText and primary.
- **In code,** a style is kept as JSON and read through `CmsResolvedCardStyle`. Colours come from the palette, the dark one when dark.

## The section carousel

A container whose layout is `carousel` (a section's `childrenLayout: carousel`) is now paged, not stacked. It uses the same `CmsPagedCarousel` with page dots, one block per page, and its height follows the page on show.

## Tests and the check

**Tests:** `CmsCardsTests` has 21 tests: card styles against the shared table, choosing, merging, colours and tones; views decoding, streaming, merging, refetched columns and the whole answer; the block's decoding, caps, variants, conditions, dates, places, groups, loading, headers with totals, slots and inputs, aliases and closing; a written card waiting on its query, failing and filling, and which slots wait inline.

```bash
swift test --filter "CmsCardsTests|CmsListRowsTests|CmsListStylesTests"
```

**Simulator check:** an iPhone 17 Pro (iOS 26.4) against a local stand-in for the CMS routes. Its view streams the base at once and the source two seconds later; one row's source fails the first time, and a logo answers 404. In light and dark, it showed:
- placeholders, then the filled values;
- the payday question with Yes and No;
- the failed row's "Couldn't load this" with Try again;
- the group header's total;
- the carousel's dots and count, and autoplay;
- a toned tip card;
- the section carousel.

**A written card waiting on its query:** the masthead page on the iPhone 17 Pro, with `me` answering after four seconds, in light and dark:
- First the date, "Good afternoon" and a placeholder for the name, with the cards below already in place.
- Then "Good afternoon Sam", with nothing moving.
- A card reading a query that fails the first time showed "Couldn't load this" with Try again; pressing it filled the card ("Estimated £358.20").

## Limits

- **Not checked by tapping:** pressing a button, a card or close on the simulator. The stand-in app isn't built with the SDK's simulator tools.
- **Autoplay** runs on a timer and doesn't stop while a person drags.
- **Selection-driven views:** a view whose base reads a selection refetches when its own `invalidate` runs, not yet on every selection change.
