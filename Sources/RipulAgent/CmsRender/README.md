# CmsRender — Native CMS Renderer

SwiftUI **second interpreter** of the same CMS page-definition JSON the web
renders. The wire format is defined by
`chrome-extension/src/api/services/cmsDefinitionsService.ts` (which mirrors
`packages/api/src/cmsDefinitions/types.ts`); this module decodes and renders
it natively with **no web-view fallbacks**. Unknown block types render an
honest dashed placeholder (`CmsUnsupportedBlockView`) naming the type — a new
block shipped in a web deploy never breaks installed apps; it renders as a
placeholder until its native twin ships.

The one embedded web surface is `agentChat`, and it is *not* a fallback: in
this product chat rendering is the web chat everywhere (the native app's own
chat screen is `AgentView`), so the block reuses the app's canonical chat
component.

---

## 1. Doctrine (user-mandated, in priority order)

These were established explicitly during the 2026-07-04 build-out and govern
every future port:

> **Rule 0 — native-first, always. This overrides everything below.** A block
> port MUST use the platform's native control and interaction pattern wherever
> one exists. If iOS has an established pattern for the thing, you build THAT —
> you never re-skin the web component's HTML/CSS as SwiftUI. Re-creating the
> web look is a **defect, not fidelity**. Reach for the system control first:
> a sidebar → `List(.listStyle(.sidebar))` with `Label` rows,
> `DisclosureGroup` accordions and system selection; a menu → `Menu`/`Picker`;
> a date → `DatePicker`/`UICalendarView`; a modal → a sheet with detents; a
> segmented control → `Picker(.segmented)`. Web presentation knobs that have
> no native equivalent (variant styles, CSS typography, hand-drawn washes) are
> **dropped**, not emulated — keep only the ones that map to a real theming
> intent. Mirror the block's *semantics* (§1.1); rebuild its *presentation*
> natively. Ask "what would a hand-built native app do here?" and do that.

1. **Semantics exact, presentation native — never pixel-for-pixel.**
   Split every block port into (a) *semantics*: props contract, published
   output rows, predicate folds, binding resolution — mirrored EXACTLY,
   porting pure TS modules function-for-function; and (b) *presentation*:
   rebuilt with the best native control. Examples:
   - `CmsDatePredicate.swift` is a function-for-function port of
     `datePredicate.ts` (half-open `[from,to)` folds, `between`
     normalisation, period operators, `0001-01-01`/`9999-12-31` sentinels,
     Monday-hardcoded `thisWeek`).
   - `CmsFormatValue.swift` ports `formatValue.ts` (number pattern core
     `[#0,.]+` with inline prefix/suffix, `%` ×100, date-fns tokens via
     DateFormatter, date-only strings parse as LOCAL calendar dates).
   - The calendar's slim row is a native compact `DatePicker` + `Menu`, while
     its six-column output row matches the web to the string.
   - `sidebarNav` is a `List(.listStyle(.sidebar))` of `Label` rows with
     native `DisclosureGroup` accordions and the system selected-row
     appearance — NOT the web's styled `<button>` rows. Its variant /
     typography / background / icon-position knobs are dropped; only
     `activeColor` survives (the selection tint). Reworked after a first port
     that re-skinned the web buttons and, in the user's words, "looked nothing
     like a regular iOS sidebar" — the canonical example of a Rule-0 miss.

2. **Native control first; degrade in place; NEVER flip implementations to
   accommodate a config.** When a real native control exists
   (`UICalendarView` for month view), use it unconditionally for that
   presentation and degrade authored features to best attempt without hacks —
   lost visual semantics get **articulated in text** instead (range span →
   caption "1 Jul 2026 – 31 Dec 2026 · Between"; weekend-hiding and in-range
   tint just drop). Custom drawing is allowed only at *capability
   boundaries*: no native control exists at all (the week strip), or the
   platform lacks it (macOS / pre-iOS-16) — never because an authored prop
   doesn't fit the control.

3. **Pick containers by content lifespan.** Sheets/popovers are for quick
   selections; long-lived functional surfaces (sidebar columns a user works
   in) get lateral slide-in drawers with spatial continuity, matching the
   app's own sidebar. (The sidebar drawers were first shipped as sheets and
   reworked on this principle.)

4. **Projection is an authored decision, not renderer religion** (the
   Airtable model: views are author-defined projections of the same table).
   Whether columnar alignment aids comprehension depends on the data's use
   and cannot be inferred globally. The renderer supplies the *default*; the
   designer overrules per block via the web inspector's **"Native App"**
   group. The default carries the opinion, the prop carries the override.

---

## 2. File map

| File | Role |
|---|---|
| `CmsJSON.swift` | Open JSON value tree for `props` bags and query rows. `displayString` renders scalars (whole doubles drop `.0`). Dictionary accessors `string/double/bool/object`. |
| `CmsModels.swift` | Codable mirrors: `CmsBlock` (type/props/frame/bindings/children/hidden/visibleOn), `CmsPageBlocks` layout union (list/template/canvas/carousel/sidebar), `BlockFrame`/`ContainerFrame`, `CmsPage`, `CmsRenderDefinition` (id/pages/queries/theme), `CmsQueryDef` + `CmsQueryParamSource` (all three source variants), `CmsSiteKeySummary`. |
| `CmsClient.swift` | HTTP to llm-proxy. Owner auth = injected Clerk `getToken` closure (SDK convention, see `SessionChannelClientConfig`); visitor auth = `visitorSessionToken`. Endpoints: `GET /admin/cms-definitions[/:id]`, `GET /admin/site-keys?organizationId=default`, `POST /v1/cms-definitions/:id/queries/:slug/run`. |
| `CmsRuntime.swift` | The page-scoped data spine (§3). |
| `CmsParameterKinds.swift` | Twin of `parameterKinds.ts`: `datePredicate` + `value` kinds, projections (range/operator/date, single/list) with the web's exact waiting semantics. |
| `CmsDatePredicate.swift` | The predicate fold (§1.1). |
| `CmsFormatValue.swift` | The display-format engine (§1.1). |
| `CmsPortalTheme.swift` | `color.*` token table ⇄ `COLOR_PATHS` in `colorTokens.ts`, resolved against `PortalThemeConfig.palette` with MUI light/dark defaults. Non-tokens fall through to `CmsCss.color` (hex only today). |
| `CmsLayout.swift` | `CmsCss` (px/rem lengths, padding shorthand, hex colours) + `CmsBlockFrameModifier` (hug/fill/fixed along the stack axis) + `CmsContainerFrameModifier`. Both take a `resolve` closure so frame colours honour theme tokens. |
| `CmsBlockRegistry.swift` | type→renderer map (+ `register` for host apps); `CmsBlockView` (frame application; **hidden/off-device blocks stay MOUNTED invisibly** — zero frame, opacity 0 — so they keep feeding outputs, same rule as the web); `CmsBlockContainerView` (list/row stacks, template slots stacked `main`-first, sidebar → `CmsSidebarLayoutView`); `CmsUnsupportedBlockView`. |
| `CmsPageView.swift` | Public entry + `CmsPageLoader` (§4). Ladybug diagnostics button, drawer overlay host. |
| `CmsBrowserView.swift` | Test-bed browser: definitions → pages, per-definition test-identity menu (§4.3). |
| `CmsRuntimeDiagnostics.swift` | The runtime inspector (§7.1) with Copy. |
| `CmsSidebarLayout.swift` / `CmsDrawerOverlay.swift` | Sidebar layout collapse (§6). |
| Blocks | `CmsBlockViews.swift` (text/markdown/image/divider/section/container), `CmsRecordCardsBlock.swift`, `CmsCalendarBlocks.swift` + `CmsNativeMonthCalendar.swift`, `CmsSelectionBlocks.swift`, `CmsKpiStripBlock.swift`, `CmsAgGridBlock.swift`, `CmsParameterSetterBlock.swift`, `CmsGridViewSwitcherBlock.swift`, `CmsAgentChatBlock.swift`. |

**Decoding rule:** blocks render from RAW persisted props — the web never
runs `schemaParse` at render, so new props are absent on old instances.
Coerce **every** prop read with `?? default`.

---

## 3. CmsRuntime — the data spine

One instance per rendered page. Twin of three web contexts:

- **Query cache** (`BlockDataContext`): `queries: [slug: QueryState]`
  (idle/loading/**waiting(reason)**/ok/error). `ensureLoaded` is lazy;
  refetches keep old rows visible (state only flips to `.loading` on first
  load). Result schemas are retained per slug to type selection-sourced
  params.
- **Selections** (`QuerySelectionContext`): `selections: [slug: [row]]`.
  Selector blocks write under their **source query slug** (that drives
  cascades); control blocks publish their **output rows** under their own
  block slug (calendar bounds row, grid aggregate row) — the native
  equivalent of `useBlockOutput`, which on the web also writes into the
  selection store.
- **Parameters** (`ParameterContext`): open JSON values shaped by their kind.
  **Persisted per cmsId in UserDefaults** (`io.ripul.cms.parameters.<cmsId>`)
  because the runtime is rebuilt on every page entry — this is how the
  calendar "remembers the user's last predicate" (the web only survives SPA
  navigation; native survives relaunch).

### 3.1 paramSources resolution (twin of `resolvedParams` in BlockDataContext)

Per query: filter `paramSources` to names present in the SQL (`@name`), claim
`toParam` companions so they can't double-resolve, then per source:

1. **`parameter`** — read the store (kind default when unset), apply the
   kind's projection (`CmsParameterKinds.project`). `range` writes the param
   + its `toParam`; waiting propagates with a reason.
2. **`datePredicate`** — operator from `operatorSource`'s selected row when
   valid (else the authored default), fold via `CmsDatePredicate.bounds`,
   write param + `toParam`. `any` needs no date.
3. **selection** — `single`: `selectedRow[column]`; missing → waiting unless
   `optional` (then SQL NULL). `multi`: every selected row's value; empty →
   waiting unless `optional` (then empty array — `IN UNNEST([])`). Param
   types derive from the source query's last result schema.

Writes trigger `refetchQueriesDepending`: any non-idle query with a matching
source re-resolves after its debounce (`max(debounceMs ?? 300)`); a source
with `autoRefresh: false` pins the query. A stable sorted-key hash
(`stableHash`) dedupes no-op re-runs.

### 3.2 Binding resolution (twin of `resolveBindings.ts`)

- **Direct bindings** — `resolvedProps(for: block)` deep-applies
  `block.bindings` onto the props tree, including **dot-path keys into
  arrays** (`items.0.value`), walking objects by key and arrays by index. A
  resolved binding replaces the whole value (often with a **number** —
  always read via `displayString`, never the string-only accessor; this
  exact bug kept KPIs blank). No source row → static value stays. A binding
  `format` yields the formatted string.
- **Inline tokens** — `resolveTemplate`: `@slug.column` against that slug's
  selected/output row, `@column` against a repeater row context,
  `|{pattern}` suffix through the format engine, `\@` escape. Unresolved
  tokens stay **literal** (visible unbound reference, great diagnostics);
  a resolved row with a null column renders blank.

### 3.3 Channels

- `gridViewStates: [gridSlug: state]` — the GridApiRegistry twin. Switcher
  writes; the grid merges (§5.3).
- `openDrawer: DrawerRequest?` — sidebar burgers publish; `CmsPageView`'s
  overlay renders (§6).

---

## 4. Loading, identity, and RLS

### 4.1 Owner path (default)
`GET /admin/cms-definitions/:id` with the Clerk token, then resolve the RLS
context: pick the site key whose `cmsDefinitionId` matches, set
`client.siteKeyId` (internal `sk_…`, sent as body `siteKeyId` on every run)
and `client.siteKeyPublishable` (`pk_…`, inherited by agentChat).

> **Without site-key context, `hydrateRlsContext` has nothing to scope by
> and owner/site RLS filters every row** — the symptom is `ok · 0 rows` /
> "No records" while the web portal shows data. This was the first real
> field bug.

### 4.2 Visitor path
`SiteKeyValidator.validate(publishableKey)` → session token + embedded
config. The token becomes the Bearer for all runs (the server derives the
RLS site key from the token's auth context; body `siteKeyId` unnecessary).
The definition comes from `config.cms` (pages/queries/theme) — **never
`/admin`**, matching how real portals consume config. Pages with
`requiresAuth != false` are hidden; opening one via slug explains "requires
sign-in" rather than 404ing.

### 4.3 Test bed (`CmsBrowserView`)
Lists every owned definition (admin list + per-definition fetch for pages)
and all site keys. Each definition's section header has a test-identity
menu: **Owner (Clerk)** or **Visitor · <site key>** per linked key (multiple
keys per definition are all offered — the site is an explicit pick, not
first-linked). Visitor mode dims `requiresAuth` pages with a lock.

Not yet simulatable: a **signed-in member** (role-bearing visitor via the
directory/verified-email join). Needs member impersonation or a second
account; decide when role-gated pages matter.

---

## 5. Block notes (the non-obvious ones)

### 5.1 recordCards — mobile-view mirror
Scoped deliberately to the web's sub-`sm`/`forceMobileView` presentation:
one phone-width column (420pt cap), fields stacked in flow (labels above),
banner/avatar images, `TextElement` titles (`{text, typography}`) with
per-card `@column` tokens. **Card surface** = the portal PAPER colour for
outlined/elevated (so cards read as cards — the web's `Paper`
`background.paper`); `flat` is transparent; `cardFrame` honoured
(token-aware `background`, `borderRadius`, `borderWidth`/`borderColor`,
`shadow` token → approximate SwiftUI shadow). Title/label/value colours
resolve through the theme (tokens like `color.secondary`, not hex-only).
**Field source precedence** = shared column view (`columnViewRef`) →
inline `fields` → schema (the web's
`columnViewColumns ?? sharedColumns ?? props.fields`). `columnViews` are
loaded from the definition (owner + visitor paths) into
`runtime.columnViews` keyed by slug; a block's `columnViewRef` resolves to
that view's curated/ordered/labelled columns — which carry per-field
`image` config, so carddemo's `headshot` (image config lives in the
`employee_columns` view, NOT the block) renders as a photo. Each field
honours key/valueFrom/label/visible/format/checkbox **plus `image`**
(card-style: full-width 120pt, `fit`, `shape` square/rounded/circle).
NOTE: the web's name-heuristic `isImage` only fires for FOREIGN lookup
columns — plain columns stay text on both sides, so native does NOT
auto-detect image columns by name. Deferred: `columnDefsRef` (a columnDefs
BLOCK by slug, ranks below columnViewRef) and foreign-column enrichment.
Selection modes none/single/multi + checkbox + `suppressRowClickSelection`;
`selectAllByDefault` seeds ONCE, never stomps an existing selection, and
applies in dropdown mode too (web seeds before its display-mode branch).
Dropdown mode = collapsed control honouring the web's `dropdownDisplay`
vocabulary (`chips` default = label chips + "+N"; `avatars` = overlapping
28pt thumbnails from the image column, initial fallback, AvatarGroup "+N"
surplus, count caption; `count` = "N records selected"; `card` degrades to
chips) → full-screen native list sheet with Select all/Clear. **Read-only**
until the mutations client exists.

### 5.2 simpleCalendar — full mirror
Three faces: custom week strip; **compact custom month grid** with
native-style swipe paging (drag follows the finger — `simultaneousGesture`,
or a plain gesture starves inside the page scroll — edge-slide transition
keyed by month identity, static weekday header; USER-CHOSEN over
`UICalendarView` after weighing the trade: the system control has no
typography/density API — `CmsNativeMonthCalendar` kept unused); slim row
(`Menu` operator + custom **date chips** twinning the web's DateDropdown:
portal-paper bordered chip, `MMM d, yyyy`, `dateDropdownTypography`
size/weight/colour, chevron follows text colour, tap opens a graphical
DatePicker sheet that closes on pick). Colour model: accent chain =
titleTypography → portal primary; selection = selectionColor → accent with
contrast text; `props.backgroundColor` is RAW CSS on the web (tokens are
NOT resolved → transparent, the block frame's fill shows through) — mirror
exactly. Type scale fixed: title 14/600, day labels 12/500 single-letter
(`EEEEE`), dates 13/400 (bold = TODAY, not selected), predicate 12, slim
operator 14. Runtime grid↔slim toggle persisted per block instance
(`io.ripul.cms.calendarMode.<cmsId>.<slug>` — twin of the web's
localStorage). Publishes the web's exact six-column output row under
its slug: `date, date_start, date_end, from, to(exclusive), operator(RAW
value: eq/between/thisYear/…)`; `any` = open range; periods fold from today
with no pick; no-pick publishes nothing. Two-way `parameterId` binding:
writes `{operator,start,end}` on change AND restores from the (persisted)
parameter on mount, anchoring the visible month.

### 5.3 agGrid — authored projections + saved views
Web props added (in `AgGridBlock.tsx`, "Native App" group):
`nativePresentation: auto|list|cards|grid`, `nativeColumns` (CSV
reduced/ordered set), `nativeScroll: contained|page` (contained = records
scroll inside the block's `height`, web parity, default),
`nativeViewToggle` (reader toggle, below).

- **reader view toggle** (`nativeViewToggle`, designer opt-in): a segmented
  control in the toolbar lets the reader flip between the browse
  presentation and the spreadsheet grid at runtime. The pick is stored as an
  abstract INTENT ("browse"/"grid", persisted per device at
  `io.ripul.cms.gridPresentation.<cmsId>.<slug>`), not a concrete
  presentation — so a saved view that redefines browse (list vs cards)
  still gets its authored look, and an author who picked grid gets list as
  the browse segment. Since the toggle reads effective (view-merged) props,
  views can enable/suppress it individually.

- **list** (auto default): rows composed from column config — first
  non-group column = title, first numeric/formatted = bold trailing, next
  two = subtitle. ⓘ opens the **row detail sheet** (every visible column —
  the answer to "22 columns on a phone"; always the FULL set, not the
  reduced native set). Search field (`enableFiltering`, client-side
  contains) + sort `Menu` (`enableSorting`).
- **grouping**: groups start **COLLAPSED** (AG Grid's
  `groupDefaultExpanded` defaults to 0) as summary rows — chevron, **pinned
  (frozen) fields first in bold** (only values UNIFORM across the group;
  varying values are omitted, not misrepresented), group value in secondary,
  count badge, and the group's aggregates on a second line. Tap to expand;
  `suppressGroupExpand` = locked labels. `hideDetailValue` blanks leaf cells
  only; `excludeFromTotals` hides from the grand total only (aggregate still
  computed/published).
- **grand totals**: pinned column-aligned bottom row inside the literal
  grid (below the vertical scroll, inside the h-scroll); wrapping
  label/value tiles (adaptive ≥130pt) in list/cards, per user direction.
- **cards**: synthesises a recordCards block from the grid config —
  presentation-only, all shared machinery.
- **grid**: true two-axis native grid — h-scroll, tap-to-sort headers,
  lazy striped rows, authored widths (64…320 clamp), height from the block
  prop. Read-only. Grouping mirrors AG Grid's table semantics: the grouped
  column is hidden and a leading auto group column (180pt) takes its place;
  group rows are column-aligned (chevron + value + count in the auto
  column, per-group aggregates under their own columns via the shared
  `computeTotals` fold); leaf rows indent with a blank auto-column cell.
  Same expansion state (`expandedGroups`) as the list projection, so
  flipping presentations keeps open groups open.
- **aggregates**: `computeTotals` (twin of `computeAggTotals`) publishes
  `${key}_${aggFunc}` + `row_count` under the block slug with a no-change
  guard. SHARED with group summaries so they can't drift.
- **saved views** (gridViewSwitcher): a view's `state` =
  `{...viewProps, filterModel, sortModel, columnOrder}` where viewProps is
  the FULL prop set minus data-source keys — and web `setState` is a
  **props-override merge**. Native does the identical merge (so views can
  change columns, totals, even `nativePresentation` per view), seeds sort
  from `sortModel[0]`, applies `columnOrder` before the `nativeColumns`
  reduction, re-publishes aggregates, and degrades only `filterModel`.
  Switcher: the **system segmented control** (`Picker.segmented`) — user
  mandate after two rounds of hand-rolled glass chips ("STOP trying to
  emulate it"): first-class control, the iOS 26 SDK supplies the Liquid
  Glass appearance and sliding selection itself. Design-time "Base" never
  shows; last pick persisted per block (replaces `?view=` deep links).
- **header styling**: `headerBgColor`/`headerTextColor`/`headerFontSize`/
  `headerFontWeight` (the web's `header` inspector group) style the grid
  projection's column header row, auto group column included.

### 5.4 kpiStrip
Items resolve through `resolvedProps` (dot-path bindings — real pages bind
`items.N.value ← gridSlug.<col>_<agg>` with NO tokens in props), then
inline tokens, then the item `format`. `responsiveText` → native
`minimumScaleFactor` (not CSS container queries); row+wrap → adaptive grid.

### 5.5 parameterSetter (headless)
Enforces its constant into the parameter store on appear, using
`ParameterBlock.tsx`'s exact value shapes (value kind: first + CSV list +
type; datePredicate kind: operator/start/end nulling rules). **This was the
missing KPI link on calendardemo** — without it `all_employees` never
resolved and the grid query waited forever.

### 5.6 fieldGrid & detailHeader
`detailHeader`: full mirror — banner (bgColor → theme primary; textColor →
contrast of the banner), title/subtitle resolve `@query.column` tokens
against the watched query's selection, `autoHide` hides it on the list,
back chevron = `clearSelection` (returns to the list) or `navigatePage`.
`fieldGrid`: READ-ONLY form v1 bound to `bindQuerySlug`'s shared selection
(falling back to the first row). Mirrored: recordPicker title mode (native
Menu driving the shared selection; `hidePickerWhenSingle`), collapsible /
startCollapsed, titleDivider, flow layout (auto columns by `minColWidth`
via adaptive grid / `fixedCols`; gap+padding in theme units ×8),
`valueStyle` outlined/underline/plain, `labelPlacement` inset/above/left,
field formats. Degradations: `layoutMode: grid` renders as flow;
`fieldGroups` and `columnDefsRef`/`columnViewRef` deferred; Edit/Save/
Delete and editing await the mutations client (`maxCols` also degrades —
adaptive grids have no column cap). WAC test pages: employees, companies,
rota-edit, rota-components.

### 5.7 agentChat
Embeds `AgentView` (component reuse, §0). Prop mapping: `siteKey` override,
else **inherit the portal's publishable key** (`client.siteKeyPublishable`)
— without inheritance the embedded app rides the shared cookie session and
shows the user's own chat instead of the portal-scoped agent; `theme`,
`newChat`, `initialPrompt`; block `title` as native header (embedded header
hidden); visitor mode passes the session token so the embed skips
re-validation. Height: fixed `height` prop, or fill when `frame.size ==
"fill"` **or the legacy `props.height == "fill"`** (the Size control's
older convention — both must be checked). Degradations: `undocked` renders
docked; per-block `viewContextId`/`promptCollectionId`/`toolCollectionIds`
overrides are NOT yet threaded into the embed hash (site-key defaults
apply).

---

## 6. Layout system

- **hug/fill/fixed** (`BlockFrame.size`) along the containing stack's axis;
  container frames map direction/gap/align; theme-token colours resolve via
  the runtime closure.
- **sidebar layout** (compact): main slot full-width; side columns **slide
  in as page-level drawers** (`CmsDrawerOverlay`, owned by `CmsPageView` so
  the scrim covers the viewport): 320pt panel in the portal `paper` colour,
  the app-sidebar spring (`response 0.32, damping 0.86`), scrim-tap or
  drag-toward-edge dismiss. How they OPEN is authored in **page settings**
  (`nativeSidebarIcon` / `nativeSidebarEdgeSwipe`, Mobile group): default =
  **edge swipe on, icon row off** (the in-flow burger strip costs a
  horizontal row); opting the icon on restores the web's space-between
  burger bar. Edge swipe = simultaneous drag starting within 44pt of the
  layout edge, horizontal-dominant, ≥45pt travel.
- **Drawer + fill**: a ScrollView proposes unbounded height, so fill
  children collapse to ideal — the drawer therefore **skips the scroll**
  when its slot `containsFill` (recursive; checks `frame.size == "fill"` OR
  legacy `props.height == "fill"`), rendering a height-bound column instead.
- **Web conflict rules** (researched, for the future nav merge): below 960px
  the web moves sidebar columns into MUI drawers; `AppSidebarMergeContext`
  makes the page's LEFT drawer the *host* and the app-nav (`sidebarNav`
  drawer mode) a *guest* behind a "Menu ⇄ Page" toggle; right-only pages get
  two independent burgers; the system is deliberately left-favouring. The
  native merge lands with a `sidebarNav` twin, which first needs **native
  page routing**.
- PoC simplifications still standing: template slots stack vertically
  (`main` first); canvas/carousel items stack.

---

## 7. Debugging & workflows

### 7.1 Runtime inspector (build it into your loop)
Ladybug button on every rendered page → live per-query state (with
**waiting reasons**), parameter values, selections/output rows — and a
**Copy** button producing a paste-able report. This cracked the KPI chain in
one paste (proved the grid had published `hours_worked_sum: 188.78` while
the KPI stayed blank → the bug had to be in the KPI's read path). Use it
before theorising.

### 7.2 Inspecting live definitions from the Mac
`open -a Ripul` (the web view must be foregrounded or peer queries time
out), then `device_evaluate`:
`await window.Clerk.session.getToken()` → `fetch('https://llm-proxy.ripul.io/admin/cms-definitions/<id>')`.
Return **strings** (`JSON.stringify`) — the serializer truncates nested
objects to `[max depth]`. Test data lives on `cms_x5xpger1lv3j`
("WAC Customer Portal"); the KPI/calendar/grid test page is `calendardemo`.

### 7.3 Device deploy loop
`/tmp/cms-device-deploy.sh`: generic-destination build (pinned
`-derivedDataPath build`) **gated on BUILD SUCCEEDED** → `devicectl device
install app` to the 17 Pro Max (CoreDevice UUID `B1982F55-6ACE-5B37-8EE5-2C1A62A4C273`)
over Wi-Fi. Notes:
- Launch multi-minute jobs detached (`nohup … & disown` → poll logfile);
  session-tied background jobs die on CLI recycle.
- Installs are **silent** (a dev build transfers in seconds; the icon ring
  is a sub-second flicker). Proof = `App installed:` +
  `devicectl device process launch io.ripul.app` (visibly opens the app —
  also rules out the stale-process trap; installs do NOT kill the running
  app, so always force-quit).
- The device build catches iOS-only availability errors that `swift build`
  (macOS floor) passes — e.g. conditional ToolbarItems
  (`ToolbarContentBuilder.buildIf`) are iOS 16+ while the package floor is
  iOS 15; put conditions INSIDE a ToolbarItem's ViewBuilder.
- `git add` with repo-root-relative paths fails from inside `ripul-ios-sdk/`
  — always commit from the repo root (this silently broke two deploy chains).

### 7.4 Field-bug case log (what actually went wrong, in order)
1. "No records" → missing site-key context in query runs (§4.1).
2. KPI blank → three stacked causes, peeled in order: no `parameterSetter`
   twin (query waiting) → dot-path bindings not applied (`items.0.value`)
   → bound NUMBER read with string-only accessor.
3. Pinned fields absent from group headers → they weren't pinned in the
   *grouped view* (views are independent prop sets; a pin made in one view
   doesn't exist in another).
4. Agent block showed the user's own chat → missing site-key inheritance.
5. Agent block not filling the drawer → ScrollView height collapse + the
   legacy `props.height == "fill"` convention.

---

## 8. Known gaps / agreed queue

**Queue (in order):**
1. ~~Native page routing~~ — SHIPPED (81c426140). `CmsRuntime.navigate(
   toPage:viewRef:)` publishes `pendingNavigation`; `CmsPageLoader.show`
   swaps the rendered page in place (runtime/selections/params survive —
   the web's SPA reading; `availablePages` respects visitor visibility;
   `currentPageSlug` drives nav active states). `?view=` deep links ride
   `GridViewRequest`, consumed by the matching gridViewSwitcher.
2. ~~sidebarNav/topNav twins~~ — SHIPPED (81c426140), `CmsNavShared.swift`
   (one recursive NavItem model + NAV_ICONS→SF Symbols map + action
   performer) and `CmsNavBlocks.swift`. sidebarNav: variants
   text/pill/underline, icon position, accordion children (auto-expand on
   active descendant), drawer mode reuses the page drawer with itself
   inline. topNav: zone groups (item.align over block alignment), children
   as nested native Menus, `collapseOnMobile` → burger Menu in compact
   width. Degradations: slot contributions (`slotId`) drop; `block` embeds
   (e.g. userAccount) render as disabled labels; mutation/export actions
   disabled until the mutations client; sticky/hover ignored.
3. **Mutations client** — `POST /v1/…/mutations/:slug/run`; makes
   recordCards/grids editable (FieldInput equivalents, save/autosave,
   delete confirmation). Also unlocks nav `mutation` actions and the
   `userAccount` embed question.
4. **TS↔Swift shared fixtures** — JSON in/out vectors for paramSources
   resolution, binding resolution, predicate folds, format patterns; run by
   both test suites. This is the drift fence and should land before the
   block surface grows much further.
5. **App-nav drawer merge** (§6) — now unblocked by routing + sidebarNav.

**Shell pattern (SHIPPED, e50da3eef):** `cms.shellPageId` designates a page
as persistent chrome; `present()` renders the shell once and routes pages
through `runtime.outletPage` into the `pageOutlet` twin (crossfade,
`.id(page.id)` so per-page onAppear hooks fire). Edge-swipe slots are
lifecycle-owned: views register on appear and unregister on disappear only
if the registration still points at their own slot — the shell's drawer nav
keeps the LEFT edge across navigations while each routed page's sidebar
layout brings its own edges. One CmsRuntime spans shell + routed pages
(the web resets selection contexts per outlet page — accepted divergence;
block slugs differ per page). Known cosmetic gap: the host nav-bar title
shows the shell page's title, not the routed page's.

**Smaller follow-ups:** filterModel subset (contains/equals/range) for saved
views; per-column native toggle in the web column editor (graduating
`nativeColumns`); drawer-vs-sheet as a designer option; agentChat per-block
config overrides; signed-in member test identity; rota timeline dot colours
(`TimelineColorContext` twin); "start expanded" grouping option; varying
pinned-value policy (currently omit; alternative "first +N").

**Deliberately out of scope:** design-time tooling (editor/inspector/AI tab
stay web-only — the mapping layer is a runtime concern); pixel parity of any
kind.
