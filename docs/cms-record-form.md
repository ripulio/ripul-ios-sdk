# A record's form, on iPhone

The iPhone half of `docs/plans/cms-record-form.md` (Peter, 29 October 2026: "Can you now look at the add/edit shift flows and port them across to CMS? Again lean away from specific WAC components"). One form adds and edits a record. It is described once on the mutation (`action.form`) and opened the same way from a button, a list row or a card. WAC's shift editor (`WACAddNewRecordVC`) is one configuration of it.

The shapes and the expression language are the web's, settled in the plan ("Settled while building (web)"): `chrome-extension/packages/shared-types/src/cmsActions.ts` and `cmsFormExpr.ts`. The iPhone follows them to the same rules.

| File | What it holds |
|---|---|
| `CmsRecordForm.swift` | The engine. It holds the layout (`CmsFormDef`: title, sections, rows, a section's summary, `computed`) and the row form (`CmsRowFormSpec`: `mutationSlug`, `values`, `deleteMutationSlug`, `load`). It also holds the expression language (`CmsFormExpr`, `CmsFormScope`), formats and templates (`CmsFormText`), and the live values (`CmsFormValues`). For list inputs it has `listItems`, `listWire`, and a draft filled from a row (`CmsActionForm.draft(_:values:)`). |
| `CmsRecordFormSheet.swift` | The sheet. A system `Form` holds the sections, the rows of tiles, a list's items and the summary. Save sits in the bar and Delete at the foot. The file also has the list item editor, the duration field, the choice picker with pictures, and the presenter for a row's or card's form (`CmsRecordFormPresenter`). |
| `CmsFormSteps.swift` | Steps, `showWhen`, waiting and creatable choices: the shared rules, held to `cmsFormSteps.cases.json`. |
| `CmsActionInputs.swift` | The inputs gain these fields: `look`, `multiline`, `fields`, `addLabel`, `removedItems`, `unit`, `hidden`, `fromComputed`, `picker`, `showWhen`, `choiceStyle` and `searchable`, plus `optionsQuery.imageColumn` and `image`. The draft gains a `list` case (its items and the removed ones). |
| `CmsDatePicker.swift` | How a date picker opens (`CmsDatePickerStyle`), the floating picker's content, the row a `floating` or `inline` field shows, and the inline picker. The record form and the action input sheet both use them. |

## The form

- **Title:** a template over the inputs and computed values (`{worked|duration}` gives "8h").
- **Sections:**
  - `items` are input names and `{ row: [...] }`, with an optional `heading`.
  - `collapsible` sections start closed and open from their heading.
  - A section's `summary: { lines, total }` holds label, detail and amount lines, then the total. A line with `input` can be tapped to edit that input in a small sheet.
  - Inputs no section names follow in a last section. Inputs that `values` bound but no section names (the key) are sent but never shown. Without a layout, only `id` is kept back.
- **Tiles in a row:**
  - A timestamp shows its time big over a short date, and a tap opens its picker (see below). An empty one reads "Add".
  - A list shows "Add break" (its `addLabel`) and how many items it has; its items are listed under the row.
  - Other inputs show their control under the label.
- **Controls:** native throughout: text fields, `multiline` text, toggles and date pickers.
  - **Choices from a query:** a menu, or a pushed list with a picture beside each choice (`optionsQuery.imageColumn` with an image chain).
  - **Durations** (`unit: 'seconds' | 'minutes'` on an integer): edited as hours and minutes and sent in that unit.
- **List inputs** (`type: 'list'`, with `fields`):
  - "Add …" opens a small sheet of the item's visible fields; a hidden field takes its `defaultValue` (a break's `break_type`).
  - An item reads as its visible fields joined with " · ": a duration as "30 min", a true truth as its label.
  - A tap edits an item and a swipe removes it. Items keep their own keys (`id`).
  - With `removedItems: { flag }`, a removed item that came with the record is sent as `{ id, <flag>: true }`.
  - The list is sent as its JSON text, as a json input is. Filled from a row, it accepts an array or JSON text holding one.
- **Saving:**
  - Save is enabled once the form is valid, and confirms first when the mutation has a confirm message.
  - After a save the form closes, the mutation's `invalidateQueries` refresh, and its `successMessage` shows as the runtime's notice at the page's foot (`CmsRuntime.showNotice`, drawn by `CmsNoticeView`).
  - `fromComputed` puts a computed value into its input at save.
- **A run's `warning`:** when an endpoint mutation's follow-up call fails (`endpoint.then`), the run still succeeds and its `warning` shows beside the success message, in the warning colour, for 6 seconds rather than 3. The form still closes and the invalidations still run. `CmsRuntime.runMutation` raises it, so action buttons and cards show it too.
- **While a row's record loads** (`load`), the title stays blank with the fields' placeholders, rather than reading the default times.
- **A summary line's detail is hidden** while any of its slots fills blank (before a job is chosen, "1 h ×" doesn't show), as on the web. The amount is blank then too.
- **Closing with changes** asks "Discard your changes?", with Discard and Keep editing; the sheet can't be swiped away while it has changes.
- **Delete** (with `deleteMutationSlug`) runs after that mutation's confirm message ("Delete this?" by default), with the same values (the row's key). `deleteLabel` ("Archive") names the row and the alert's button, as on the web; without it they read "Delete".

## How a date picker opens

This is plan item 9 (Peter: "the style of how [the date] pops the picker should be configurable, where one choice supports the floating style in WAC").

- **Where it's set:** `picker: 'sheet' | 'floating' | 'inline'` on a date or timestamp input, with `form.picker` as the form's default. The input's own setting wins. Unset or unknown means `sheet`, as the web's `actionPickerFor` does.
- **`sheet`** is the behaviour before this change, and it stays the default. A tile opens a sheet with the graphical calendar and the time. A field row is the system's own compact `DatePicker`.
- **`floating`** is the system's popover, anchored to the tile's or row's own bounds: below it, or above when there's no room below, and never covering it (the system's glass on iOS 26).
  - **Why UIKit:** inside a sheet on iPhone, SwiftUI's `.popover` with `.presentationCompactAdaptation(.popover)` fell back to a side placement over the tile and the sheet's bar (seen in WAC Next on iOS 27). So iOS presents it through UIKit (`cmsAnchoredPopover`, `CmsPopoverAnchor`): a `UIPopoverPresentationController` whose source is the tile, with arrows only up or down, and an adaptive style of `.none`. The content is refreshed while it is open, so the tile and title follow the wheels. Tapping outside closes it and keeps what was picked, as the system does. macOS keeps SwiftUI's `.popover`.
  - A timestamp shows a "Date" row with a `.compact` date pill (which opens the system's calendar), then the time as `.wheel`, then Done.
  - A date shows the `.graphical` calendar, then Done.
  - **Done** is plain words in the theme's accent, centred under a hairline, as WAC's and the system's popovers have it.
  - The tile or row shows `chevron.up.chevron.down` beside the value.
- **`inline`**: a tap opens the `.graphical` picker in place, with the time under it for a timestamp, and tapping again closes it. A tile's picker opens straight under its row, above a list's items. The open value is tinted.
- **Where it applies:** wherever an action input is edited. That's the record form's tiles and rows, a row's or card's form, and an action button's input sheet (`CmsActionInputSheet`, which reads only the input's own `picker`, since it has no form). In the input sheet, an optional date keeps its toggle; the row shows once it is on. A field's `after` still bounds the picker there.
- **`after`:** a floating or inline picker for an input that must come after another (`end` after `start`) offers nothing earlier than it, as on the web. Moving the start still moves the end with it.
- **Where iPhone differs from the web, on purpose:** on a tile, the web opens `inline` as floating, since a row of tiles has no room under one tile; a Form row has room, so the iPhone opens it under the row. The web's time columns step by 5 minutes; the iPhone's are the system's wheels, by the minute.
- **Limit:** the SDK's screen inspector can't see inside a popover (as with a full-screen cover), so a test presses Done by its position.

## Steps, conditions and choices

This is the iPhone half of `docs/plans/cms-add-job.md` (Peter, 30 October 2026: "components need to be generic and reusable and get to the WAC look and feel via design levers over config"). The rules are the web's (`packages/shared-types/src/cmsFormSteps.ts`, `cmsActions.ts`), ported to `CmsFormSteps.swift` and held to the same cases table (`cmsFormSteps.cases.json`, `CmsFormStepsTests`). The `body` cases are the worker's and aren't ported.

- **`form.steps`:** each step is a screen pushed in the record-form sheet's own navigation stack, so the system's back button and swipe go back, keeping what was entered.
  - A step shows its progress, its `title` as the progress line, its `question` big and its `description`, then its sections.
  - **`form.progress`:** `bar` (the default) is a `ProgressView`; `count` reads "Step 2 of 4"; `none` shows nothing.
  - **The button** sits at the foot. It reads the step's `nextLabel` ("Continue"), and on the last step `form.submitLabel` ("Save"), which runs the mutation.
  - **Next** checks only that step's inputs, by the shared rules. What's wanting says why beside it ("Job name is required.") until it's put right.
  - **Which steps show,** and which inputs each asks, come from `CmsFormSteps.visible`. A step whose `showWhen` fails is skipped, and inputs no step names join the last step shown. Cancel sits on the first step only; Delete, for a row form, sits there too.
  - **Without steps,** the form is unchanged.
- **`showWhen` on an input:** `{ input, in?, filled? }`. An input that isn't shown isn't drawn, isn't required and isn't sent (`CmsActionForm.validate` leaves it out). The chain follows `CmsFormSteps.hidden`. Comparison is as text: a number listed in `in` is its text, and a toggle is "true" or "false".
- **`choiceStyle`:**
  - **`menu`:** the system's pop-up menu. It's the default without pictures.
  - **`list`:** a pushed list of the system's rows with a checkmark. It's the default with pictures, a search field or an add row; a `menu` that is searchable or creatable is drawn as a list.
  - **`inline`:** the system's inline picker, rows in place with a checkmark. An optional input's first row is its empty choice: its `optionsQuery.emptyChoice` with the filled line, else "None". This lets a choice be taken back, as the web's inline list does (`CmsActionForm.emptyChoice`, held to the `emptyChoice` cases).
- **`searchable: true`:** the list gets the system's search field (`.searchable`), matching labels and descriptions.
- **Descriptions** show under a choice's label: static `options.choices[].description`, or `optionsQuery.descriptionColumn`.
- **`optionsQuery.params`:** templates over the form's values. The list runs its query with them (its own run, not the page's shared one). Until each has a value it reads "Choose <label> first". Changing an input a list's params name clears that list's choice, and anything that depends on it in turn.
- **`optionsQuery.create`:**
  - In a pushed list, a searched text that matches no choice shows a row labelled `create.label` (`Add "<text>"`).
  - Tapping it runs `create.mutationSlug` with the list's params and the text as `create.input`. Then it reads the run's `result` at `valuePath` (and `labelPath`), chooses that, refreshes the options and closes the list.
  - A failure shows its message and keeps the list open.
  - `CmsClient.runSavedMutationResult` now hands back the run's `result`, through `CmsRuntime.runMutationResult`.
- **`image` on a text input:** `{ chain, shape }`, the chain choice pictures use, read from a row of `{ value: <typed text>, <input name>: <typed text> }`. A picture shows beside the field about half a second after typing stops, through the site's image sources. Nothing shows when none matches.
- **Sidebar parts with `form`:** a choice list's `rowAction`, an `addRow`, a section's `headerAction` or a calendar's header button can carry `form`, the row form shape `openRowForm` uses. A tap opens that record form, filled from the choice's row (`values`, `load`, `deleteMutationSlug` as usual). An add row or a header button has no row, so its form opens empty.

- **Checked on a simulator** (iPhone 17 Pro, iOS 26.4, 30 October 2026). This was `CmsAppView` against a local stand-in carrying an add-job form shaped like wac-app's planned one: four steps, a searchable creatable industry, job titles on `params: { industry_id }`, an inline job type, frequencies with descriptions, payday fields on `showWhen`, the rate, and a Jobs choice list whose row action has `form` (`edit_job`). In light and dark:
  - **Step 1:** it read "Step 1 of 3" with the bar, "Job details" and the question. Job title read "Choose Industry first". Continue with nothing filled flagged all four fields ("Job name is required." and so on).
  - **The typed picture:** typing "KFC" showed its logo beside the field.
  - **Creating choices:** searching Industry for "boat repair" offered `Add "boat repair"`. Tapping it sent `create_industry { name }`, chose "Boat Repair" from the result's `labelPath` and closed the list. Job title then opened, and "Deckhand" offered `Use "Deckhand" as a new title`, which sent `create_job_title { industry_id: 602, name }`.
  - **Steps 2 and 3:** step 2 was pushed with the system's back button, the frequencies with their descriptions. Choosing Weekly made it "Step 3 of 4", whose payday step showed only the weekday. Next refused it blank.
  - **The last step:** step 4's button read "Add job". It sent name, industry, title, job type, frequency 4, `weekday` Friday and `hourly_pay` 11.5, and left out `pay_date` and `day_of_month`. "Job added" showed, and KFC joined the list.
  - **The row action and add row:** Costa's pencil (`rowAction.form`) opened `edit_job` filled from its row with Delete, and saving sent `id` 9. The add row opened the steps form.
- **Limits:**
  - An `inline` choice shows its label as the picker's first row, as the system's inline picker does, so a section heading of the same words repeats it.
  - The `menu` style's items can't be reached by the SDK's screen inspector; tests tap them by position.

## A dropdown with pictures

`choiceStyle: "dropdown"`, or the theme's `inputs.choiceStyle`: `CmsDropdownChoice` in `CmsRecordFormSheet.swift`. It is used in a record form and in the plain input sheet (`CmsActionInputSheet`, for a mutation with no `form`, such as WAC in).

- **The trigger:** a regular Liquid Glass capsule (`CmsGlassCapsule`; the thin material before iOS 26) inside the form's own card, as WAC's sits in its card. It shows the chosen option's picture (a 34-point tile), label and subtitle, with the system's up-and-down chevron.
- **The list is the system's own `Menu`.** On iOS 26 it is Liquid Glass and morphs out of the trigger.
  - Each option is a `Toggle`, so the chosen one has the system's tick.
  - The toggle's label is a `Text` for the title, a second `Text` for the subtitle (`descriptionColumn`) and the picture's `Image`.
  - A `Picker` was tried first. Its rows dropped the second line, and so did a `Label` whose title held two texts.
- **Pictures:**
  - A menu can't load images while it's open. So every option's picture is resolved through the page's image cache (`CmsMarkerImageCache`, the chain the calendar markers and list rows use) when the options arrive.
  - Each is drawn into a rounded tile on white, `alwaysOriginal` so the menu keeps its colours: what WAC's `JobMenuFactory.avatarImage` does.
  - An option with no picture, or one that fails, is drawn as the same tile with its initials on its palette colour (`initialsTile`), so the rows line up. The rule is the web's, held to the `choiceTile` cases.
- **Why not a custom popover like WAC's `GlassMorphMenu`?** The system menu already does what WAC's did with the native menu: glass, the morph, the picture, the subtitle and the tick. A custom one would only add control of the direction, which is WAC's reason in commit `6441c0b7e`. Native-first wins.

## Computed values

`form.computed: { name: expression }`. They're worked out from the inputs, from a chosen option's row (`job_id.rate`) and from each other in any order (a loop is blank). The grammar is the web's:

- **Basics:** numbers, names, `+ - * /` (and `× ÷ −`), and parentheses.
- **`minutes(a, b)`:** between two moments, rounded to the minute.
- **`sum(list.field)`:** a field totalled over a list's items.
- **`sum(list, expr)`:** the expression worked out per item and totalled. Inside it a name is the item's field first, then the form's names, so unpaid break time is `sum(breaks, total_break_time * (1 - is_paid_break))`.
- **Others:** `count(list)`, `round(x[, digits])`, `min`, `max`, and `coalesce(a, b, …)`, which gives the first argument that isn't blank.
- **Blanks:** a blank operand or a division by zero makes the result blank. `true` and `false` count as 1 and 0.
- **Slots and formats:** `{name}` and `{name|format}`. The format is a column format (`0.00`, `"£"0.00`) or `duration` (minutes as "8h", "7h 30m", "0m"). An unformatted number shows at most 2 decimal places.
- **`uuid()` and `timezone()`:** a new random id and the viewer's IANA zone, both text, for `fromComputed`.
- **Text and conditions** (for WAC's leave entries, `docs/plans/cms-sick-holiday.md`): text in quotes (`'unpaid'`), comparisons `== != < <= > >=` (1 or 0; numbers as numbers, else as text; a blank side equals only a blank) and `if(c, a, b)`. A value is a `CmsFormValue`: a number, text or blank. `fromComputed` sends a text value as text: `if(count(paid_days) == 0, 'unpaid', payment_type)`. Held equal to the web's by `cmsFormExpr.cases.json` (`CmsSickHolidayPiecesTests`).

## A time of day

`type: "time"` (`HH:mm`) is the `.time` control: its draft is a moment on today's date, sent as `HH:mm` in the viewer's zone. A tile shows the time big; `floating` opens the system's time wheels alone in the popover, `inline` the wheels under the row, `sheet` the system's compact picker. `after` between two times orders them by minutes since midnight, and moving the start moves the end with it, as for timestamps. `minutes(a, b)` reads the two moments.

## A set of days

`type: "dates"` with `range: { from, to }` (two date inputs), `defaultSelection` (`all` or `none`) and `itemField`:

- **Drawn as** the system's `MultiDatePicker`, bounded to the range's days, with "2 of 3" beside the label. With no `range` it's unbounded (any day), with "3 days" beside the label. A new range makes a new picker (`.id` from the range), since the picker keeps the binding and bounds it was made with. Until both ends are set it reads "Choose the dates first." Off iOS (the macOS build of the SDK) it's a toggle per day.
- **Changing an end of the range** starts the set again: all the new range's days, or none.
- **The draft** holds the days joined with commas. The form sends plain days (`yyyy-MM-dd`); the worker turns each into `{ <itemField>: day }` when it fills an endpoint body. Filled from a row, a set reads days, timestamps or records holding the day at `itemField` (Rails' `track_hour_paid_days`).
- **`count(paid_days)`** counts the days, and `showWhen: { filled: true }` holds while one is chosen.
- **Rules:** `CmsDateSets.swift`, the web's `cmsDateSets.ts`, held equal by `cmsDateSets.cases.json`.

## Opening it

- **An action button** whose mutation has a `form` always opens it, empty apart from defaults. The inputs the button supplies are left out. A floating button's menu `primary` (WAC's "Add an entry") does the same.
- **A grid's rows:** `openRowForm: { mutationSlug, values: { input: '{column}' }, deleteMutationSlug?, load? }` makes a tap on a row of the phone list open the form filled from that row. A template that is one slot keeps the column's own value (a list's array, a number).
- **A row form by the row:** `openRowForm.variants: [{ when: { column, equals | in | empty }, mutationSlug, values, load?, deleteMutationSlug?, deleteLabel? }]`. The first whose `when` holds for the tapped row opens instead of the default (`CmsRowFormSpec.form(for:)`, applied when `CmsRecordFormRequest` is made). WAC's Records list opens a holiday's or a sick day's own form.
- **A card:** `open: { form: { … } }`, the same spec, filled from the card's row.
- **`load: { querySlug, params }`:** opening runs that query for the row (its params filled from the row) and fills the form from its first row. That's for an endpoint read of one record whose nested items aren't in the list. While it loads, the row's values show as placeholders. A failure says so and offers Try again.

## Tests and the check

- **Tests:** `CmsRecordFormTests` covers:
  - decoding (`form.computed`, a section's summary, `collapsible` starting closed, pictures on `optionsQuery`, list fields);
  - the expression language (precedence, blanks, `coalesce`, truths, `sum(list, expr)`, `count`, `round`, `min`/`max`, `minutes`);
  - formats and templates, and the live values (a chosen option's column, a computed value from another);
  - a list item's text;
  - a draft filled from a row (a list from JSON text, items keeping their `id`, a zoneless timestamp);
  - what is sent (a removed item as `{ id, _destroy: true }`, the list as JSON text), and the row form spec;
  - the date picker's style: the input's own, then the form's, then a sheet, with an unknown value counting as unset. It is kept when stored.

  ```bash
  swift test --filter CmsRecordFormTests
  ```
- **Simulator** (iPhone 17 Pro, iOS 26.4): `CmsAppView` against the local stand-in, on a page with "Add an entry" and a list of shifts. The `add_shift`, `edit_shift` and `delete_shift` mutations carry WAC's form:
  - Job;
  - a row of start | breaks | end tiles;
  - breaks with a length in seconds, paid, and a hidden `break_type`;
  - notes;
  - Earnings: base pay = worked × `coalesce(hourly_pay, job_id.rate)`, extra cash, total.

  Driven with the SDK's simulator tools, in light and dark:
  - **Empty from the button:** the title showed "1h". Choosing Corner Shop and adding a 30-minute unpaid break showed "30m" and base pay 30m × 11.00 = 5.50.
  - **Saved:** it sent ISO times, `job_id`, and the breaks as JSON with `break_type: quick_break` and `total_break_time` 1800.
  - **A row filled in:** Corner Shop's row opened the form filled: "8h", 09:00 and 17:30, its break read from JSON text, the notes, 8h × 11.00 = 88.00, and Delete. Removing the break showed "8h 30m" and 93.50.
  - **Closing:** Cancel asked "Discard your changes?".
  - **Saving the edit:** it sent `id` 42 and the removed break as `{ "_destroy": true, "id": 5 }`. "Entry saved" showed at the page's foot.
  - **Delete on Costa's row:** it asked "Delete this entry?" (that mutation's own message) and sent `id` 43.
  - **How a date picker opens** (29 October 2026): `add_shift`'s form had `picker: 'floating'`, `edit_shift`'s had `inline`, and a "Log a day" button's plain input sheet had a floating date and an inline timestamp.
    - The add form's tiles showed the chevrons. The start tile's popover held the Date pill, the wheels and Done, in light and dark. After the UIKit change, the start's and the end's cards each opened below their tile, with all three tiles still showing. Turning the wheel moved the end tile live, Done and a tap outside each closed it, and it opened again afterwards. In the input sheet, Day's card opened below its row. Turning the hour wheel moved the start from 12:00 to 14:00, and the end followed to 15:00.
    - Corner Shop's row opened with no chevrons. Its end tile opened the calendar and the time under the tiles, tinted 17:30, and a second tap closed it.
    - In the input sheet, Day's popover was anchored under its row with the graphical calendar. Picking the 31st and saving sent `day` 2026-10-31 and `until` as a timestamp.
  - **A run's warning:** with the stand-in's `add_shift` answering a `warning`, "Entry added" showed with "Step 1 (PUT …) wasn't saved: …" beside it in orange. Before a job was chosen, Base pay showed no detail.

## Limits

- **Endpoint follow-ups:** a follow-up call after an endpoint mutation (`endpoint.then`, in the plan) is the server's, not the form's.
- **Saved entries, attachments, overtime and other rates:** the plan leaves them out.
- **The duration field** steps minutes by 5.
