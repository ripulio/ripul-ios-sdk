# Theming: fonts and colours from a theme

This is the contract for every agent migrating call sites under
`docs/plans/theme-aware-codebase.md`, and for anyone writing a new view in the
SDK or the Ripul app. It says what a view writes, what the tokens are called,
what Ripul's theme document looks like, and how to check your work. If you
need a token, role or rule that is not here, ask the foundation owner (a
comment on the plan's Foundation section): do not invent one.

Nothing in this file is pending. Where a thing is not built, it says so.

The code is in `Sources/RipulAgent/ThemeCore/` (four files, compiling on iOS
and macOS). The tests are `Tests/RipulAgentTests/RipulThemeCoreTests.swift`.

## The one idea

Every token has a default, written in code, that is the system value the call
site used before: `Font.ripul(.body)` is `Font.body`, `.ripul(.textSecondary)`
is the system's `.secondary` style, `UIColor.ripul(.text)` is `UIColor.label`,
the same object. So a migrated call site draws the same pixels, and the
default theme document is empty. A theme document changes a token only by
naming it.

## What a view writes

### Fonts (SwiftUI)

| Today | Write |
|---|---|
| `.font(.body)` | `.font(.ripul(.body))` |
| `.font(.caption.weight(.semibold))` | `.font(.ripul(.caption, weight: .semibold))` |
| `.font(.headline.bold())` | `.font(.ripul(.headline).bold())` |
| `.font(.caption.monospacedDigit())` | `.font(.ripul(.caption).monospacedDigit())` |
| `.font(.caption.monospaced())` | `.font(.ripul(.caption, family: .code))` |
| `.font(.system(.caption, design: .monospaced))` | `.font(.ripul(.caption, family: .code))` |
| `.font(.system(size: 14, weight: .medium))` on text | `.font(.ripul(size: 14, weight: .medium))` |
| `.font(.system(size: 12, design: .monospaced))` | `.font(.ripul(size: 12, family: .code))` |
| `.font(.system(size: 18))` on an `Image` | `.font(.ripulIcon(size: 18))` |
| `.font(.title2)` on an `Image` | `.font(.ripulIcon(.title2))` |
| `Font.caption` as a value | `Font.ripul(.caption)` |

Rules:

- `.bold()`, `.italic()`, `.monospacedDigit()`, `.leading(...)` stay chained
  calls. `.bold()` is not `weight: .bold`: the two draw different pixels
  (measured).
- `.monospaced()` and `design: .monospaced` draw the same pixels (measured),
  so both become `family: .code`.
- A fixed size stays fixed. In a custom family it is
  `Font.custom(_:fixedSize:)`, because `.system(size:)` does not scale with
  Dynamic Type and its replacement must not either.
- A bare text style is a font wherever its type is `Font`, not only inside
  `.font(`: a property (`var titleFont: Font { flag ? .caption2 : .caption }`),
  a `return .headline`, a ternary inside `.font(...)`. Each becomes
  `.ripul(<the same style>)`. These are easy to miss: the script does not
  rewrite them, and a row that takes its fonts from such properties stays in
  the system font under a themed family (found on the session row with the
  loud document).
- A weight may be the argument or a chained call: `.ripul(.body, weight: w)`
  and `.ripul(.body).weight(w)` are the same value under every theme, whatever
  `w` is, a ternary included. Prefer the argument.
- A design chosen at run time,
  `.font(.system(.caption, design: isTag ? .monospaced : .default))`, becomes
  `.font(.ripul(.caption, family: isTag ? .code : nil))`: a nil family is the
  role's own. The ternary may also go outside,
  `.font(isTag ? .ripul(.caption, family: .code) : .ripul(.caption))`; the lint
  reads both. (`.system(.caption, design: .default)` and `.caption` are taken
  to draw the same; that one is reasoned, not measured.)
- `ripulIcon` is never themed. A font on an `Image(systemName:)` is an icon
  size, not type.
- `.rounded` and `.serif` designs have no accessor. The two `.rounded` sites
  are exempt by name (`// theme-exempt: rounded design`).
- View-level `.fontWeight()`, `.bold()` and `.italic()` are left alone.
- `View.ripulTextStyle(.eyebrow)` applies a role's font and, when a theme sets
  them, its tracking and capitals. With no theme it is `.font(.ripul(role))`.
  A call site that writes `.textCase(.uppercase)` today keeps it.

### Colours (SwiftUI)

There are two forms, and which one you write matters.

**The style form**, wherever a `ShapeStyle` is accepted (`foregroundStyle`,
`fill`, `stroke`, `background`, `tint`, `strokeBorder`):

```swift
.foregroundStyle(.ripul(.textSecondary))     // was .foregroundStyle(.secondary)
.fill(.ripul(.danger))                        // was .fill(.red)
.background(.ripul(.canvas))                  // was .background(Color(.systemBackground))
```

**The Color form**, only where a `Color` is required (a `shadow(color:)`, a
stored `Color`, a function argument, `foregroundColor`, an `.opacity()` on a
colour):

```swift
Color.ripul(.textSecondary)                   // was Color.secondary
.foregroundColor(.ripul(.textSecondary))      // was .foregroundColor(.secondary)
.shadow(color: Color.ripul(system: .black).opacity(0.2), radius: 4)
```

Why two. The text roles' defaults are SwiftUI's hierarchical styles, and the
system draws `.secondary` differently from the colour `Color.secondary` in a
list row, inside a button and in a section header (measured: in a light list
row the style is 128,128,128 and the colour is 138,138,142; in a prominent
button 128,195,255 against 36,90,142). The style form hands back the system's
own style, so it matches `.secondary` in every place tested. The Color form
hands back `Color.secondary`, which matches what `Color.secondary` drew. So:

- Replace a style with the style form and a `Color` with the Color form.
  Never turn `Color.secondary` into the style form, or `foregroundColor` into
  `foregroundStyle`: that changes pixels. The lint refuses it.
- A bare `.secondary` or `.primary` is whichever the compiler makes it. It is
  a **Color** when the other branch of its ternary is a colour
  (`flag ? .white : .primary`, `flag ? Color.accentColor : .secondary`: the
  two branches share one type, and `.white` is only a Color), when its line
  says so (`var tint: Color = .secondary`), when it is the fallback of a
  `Color?` (`tint ?? .primary` becomes `tint ?? Color.ripul(.text)`), and when it is passed to a `Color`
  parameter or returned from a function that returns `Color`. Write the Color
  form for those: `flag ? Color.ripul(.onAccent) : Color.ripul(.text)`. It is
  the **style** when it is the whole argument of a style call
  (`.foregroundStyle(.secondary)`), or both branches are hierarchy names. The
  lint knows the cases it can read from the line, and takes either form for a
  bare name passed to a parameter or returned, or beside a variable in a
  ternary (`selected ? color : .secondary`), where only the compiler knows:
  there, check the type yourself. If `color` is a `Color`, write the Color form.
- In a ternary, both sides must be the same form:
  `flag ? .ripul(.text) : .ripul(.textSecondary)`. A ternary that mixes a
  colour and a hierarchy style (`flag ? Color.accentColor : .secondary`) is
  not rewritten by the script, and by the rule above it was a `Color` on both
  sides: write the Color form for the hierarchy name and leave the accent.

**The accent is not edited.** `.tint`, `Color.accentColor`, `.accentColor` and
`UIColor.tintColor` stay as they are: the theme's accent reaches them through
the window's tint (see "What the root reaches"). `Color.ripul(.accent)` exists
for a literal that means the accent, such as `Color.blue` on a selected mark,
and that replacement is a judgement, so it needs a marked reason (below).
A read of `.tint` or `Color.accentColor` under a local `.tint(...)` is that
local tint, not the app's accent: leave it.

### UIKit

```swift
label.textColor = .ripul(.textSecondary)      // was .secondaryLabel
view.backgroundColor = .ripul(.canvas)        // was .systemBackground
label.font = .ripul(.caption)                 // was .preferredFont(forTextStyle: .caption1)
label.font = .ripul(size: 12, weight: .semibold)            // was .systemFont(ofSize: 12, weight: .semibold)
label.font = .ripul(size: 12, weight: .regular, family: .code)   // was .monospacedSystemFont(ofSize: 12, weight: .regular)
layer.borderColor = UIColor.ripul(.separator).cgColor
```

The type may be left out on either side, as UIKit code usually does:
`v.font = .preferredFont(forTextStyle: .body)` becomes `v.font = .ripul(.body)`,
`label.textColor = .placeholderText` becomes
`label.textColor = .ripul(system: .placeholderText)`. The check and the lint
read both spellings.

UIKit has no hierarchical style, so there the text roles are the label
colours: `UIColor.ripul(.textSecondary)` is `UIColor.secondaryLabel` itself.

### A system colour that no role fits

```swift
Color.ripul(system: .secondarySystemBackground)
.fill(.ripul(system: .tertiarySystemFill))
UIColor.ripul(system: .systemGray5)
Color.ripul(system: .white)        // a scrim, a shadow, a mark on a photograph
```

This draws exactly what the system colour draws and is never themed. The
check counts these apart, and the brand step decides what each becomes. Use
it when the closed table below gives no role. Do not pick the nearest role:
`secondarySystemBackground` is not `surface`.

### Colours that are not theme

Mark them and leave them: `// theme-exempt: <reason>` on the line or the line
above; `// theme-exempt-file: <reason>` in a file's first 30 lines for a
whole file. Exempt by the plan: SF Symbol sizes (use `ripulIcon`), colours
that are data (a provider's, a model's, a chat's, ANSI, syntax and diff
colours), brand marks, materials and glass, `#if DEBUG` harness views,
`CmsRender/`.

### A replacement that is a judgement

When you replace a literal with a token whose default is a different value
(`Color.blue` with `.accent`), the lint stops you. If it is right, say why on
the new line: `// theme-mapping: this blue is the selection mark`. Expect few.

### A colour that meant the app's colour

```swift
.foregroundStyle(.ripul(accentOr: .info))    // was .foregroundStyle(.ripul(.info)), itself .blue
Color.ripul(accentOr: .info)
UIColor.ripul(accentOr: .info)
```

For a system blue that was the app's own colour and not a notice (a machine's
icon, a tile with no colour of its own): the theme's accent once a theme names
one, and until then the role it was. `.ripul(.accent)` is not an identity
there. Measured on the reference screens: the system's tint and its blue are
the same pixels in light, and differ in dark (by up to 19 in a channel) and
under Increased Contrast (by up to 64).

### Controls that style their own text

A root gives a themed family to text with no font of its own, and a themed
accent to tints. Four things it cannot reach, each with a modifier that is the
system's own style while no theme names the value (so nothing changes under
the default document):

| Today | Write | Under a theme |
|---|---|---|
| `.buttonStyle(.borderedProminent)` | `.ripulProminentButtonStyle()` | the label is drawn in `onAccent` (the system draws it white whatever the fill) |
| `.buttonStyle(.glassProminent)` | `.ripulGlassProminentButtonStyle()` | the same |
| `Section("Title") { }` in a list or form | `Section(themed: "Title") { }` | the header keeps its size and weight, in the family |
| `header: { X }` of a section | `header: { RipulSectionHeader { X } }` | the same |
| `footer: { X }` of a section | `footer: { RipulSectionFooter { X } }` | the footer keeps its small size, in the family |
| `ContentUnavailableView("T", systemImage: "i", description: Text("d"))` | `ContentUnavailableView(themed: "T", systemImage: "i", description: Text("d"))` | title and description in the family |
| `Label("T", systemImage: "i")` as an empty state's label | `RipulEmptyStateLabel("T", systemImage: "i")` | the same |
| `Text("d")` in an empty state's `description:` | `Text("d").ripulEmptyStateDescription()` | the same |

Why sections need it. A grouped list chooses a header's and a footer's font
only while the environment holds no font, and the root's themed family is an
environment font, so without these a header loses its weight and a footer
grows to body size (seen in Settings under the brand document). SwiftUI has
no public way to give a family and leave a control's own choice alone.

Not inside a menu, a picker, a toolbar or a lazy stack: a `Section` there is
not a grouped list's, and a menu takes only a plain title. `ContentUnavailableView.search`
is the system's own wording and stays in the system font.

The sizes are the system's on iOS 27, read from pictures: an empty state's
title is title3 bold and its description body; a section's header is
headline and its footer footnote. They are the same in every list style,
which is not true of the system (a plain list's header differs): a limit.

### Text UIKit draws

Navigation titles (large and inline, so sheet titles too), segmented
controls and tab bar labels are set through UIKit's appearance settings by
`RipulTheme.applySystemTextAppearance()`, which `adopt` and `resetToDefaults`
call. It does nothing until a theme names a text family, restyles the bars
already on screen when one does, and puts every setting back to "not set"
when the family returns to the system's. Not reached: alerts, menus, swipe
action labels, a menu picker's value, and a navigation title on Mac
Catalyst, which the Mac draws in the window's toolbar.

### Never store a token

Call the accessor where the value is used, or where a view is made. These are
fine, because each runs again whenever the view that owns it is rebuilt, and
the read is made inside that view's body:

```swift
struct Chip: View { var tint: Color = Color.ripul(.info) }   // a view's property default
func badge(tint: Color = .ripul(.info)) -> some View          // a parameter's default
```

These are not, because nothing runs them again: a `static let`, a stored
property of a model, a controller or a singleton, a cache. The check fails a
`static let` that holds one; the others it cannot see.

## The closed table

For each literal you will meet, the one thing to write. "S" is the system
form. Anything not here: the system form if it is a system colour, a comment
on the plan if it is a raw RGB value.

| Literal | SwiftUI | UIKit |
|---|---|---|
| `.primary` as a style | `.ripul(.text)` | |
| `.secondary` as a style | `.ripul(.textSecondary)` | |
| `.tertiary` as a style | `.ripul(.textTertiary)` | |
| `.quaternary` as a style | `.ripul(.textQuaternary)` | |
| `Color.primary`, `.foregroundColor(.primary)` | `Color.ripul(.text)` | |
| `Color.secondary`, `.foregroundColor(.secondary)` | `Color.ripul(.textSecondary)` | |
| `.label` | S: `Color.ripul(system: .label)` | `.ripul(.text)` |
| `.secondaryLabel` | S: `Color.ripul(system: .secondaryLabel)` | `.ripul(.textSecondary)` |
| `.tertiaryLabel` | S | `.ripul(.textTertiary)` |
| `.quaternaryLabel` | S | `.ripul(.textQuaternary)` |
| `.tint`, `Color.accentColor`, `.tintColor` | unchanged | unchanged |
| `.systemBackground` | `.ripul(.canvas)` | `.ripul(.canvas)` |
| `.secondarySystemGroupedBackground` | `.ripul(.surface)` | `.ripul(.surface)` |
| `.systemGroupedBackground` | `.ripul(.surfaceSunken)` | `.ripul(.surfaceSunken)` |
| `.secondarySystemBackground`, `.tertiarySystemBackground`, `.tertiarySystemGroupedBackground` | S | S |
| the four fills (`.systemFill` ... `.quaternarySystemFill`) | S | S |
| `.separator` | `.ripul(.separator)` | `.ripul(.separator)` |
| `.opaqueSeparator`, `.placeholderText`, `.link` | S | S |
| `.red`, `Color.red`, `.systemRed` | `.ripul(.danger)` | `.ripul(.danger)` |
| `.orange`, `.systemOrange` | `.ripul(.warning)` | `.ripul(.warning)` |
| `.green`, `.systemGreen` | `.ripul(.success)` | `.ripul(.success)` |
| `.blue`, `.systemBlue` | `.ripul(.info)` | `.ripul(.info)` |
| `.gray`, `.systemGray` | `.ripul(.neutral)` | `.ripul(.neutral)` |
| `.systemGray2` to `.systemGray6` | S | S |
| `.white` on an accent or coloured fill | `.ripul(.onAccent)` | `.ripul(.onAccent)` |
| `.white` otherwise (scrim, highlight) | S: `.ripul(system: .white)` | S |
| `.black` | S: `.ripul(system: .black)` | S |
| `.yellow`, `.mint`, `.teal`, `.cyan`, `.indigo`, `.purple`, `.pink`, `.brown` | S (`.systemPink` ...), or exempt if it is data | S |
| `Color.clear` | unchanged, not counted | unchanged |
| `.fill`, `.fill.secondary`, `.fill.tertiary`, `.fill.quaternary`, `.background`, `.separator`, `.placeholder`, `.selection` as styles | unchanged, not counted: the system's own styles, like a material | |

The roles are named for a job, so check the job too. A red that is a
recording light, not an error, is still `.ripul(.danger)` only if it should
change when the theme's danger colour changes; if not, it is the system form.
Either keeps today's pixels; the choice decides what the brand theme does.

## Colour roles

| Role | Document name | Default (today's look) | For |
|---|---|---|---|
| `accent` | `ripul.accent` | `system:tint` | Selection, links, primary buttons, the unread mark |
| `onAccent` | `ripul.onAccent` | `#FFFFFF` | Text and icons on an accent fill |
| `canvas` | `ripul.canvas` | `system:systemBackground` | The app's background |
| `surface` | `ripul.surface` | `system:secondarySystemGroupedBackground` | Cards and grouped rows |
| `surfaceSunken` | `ripul.surfaceSunken` | `system:systemGroupedBackground` | The ground behind cards |
| `text` | `ripul.text` | `system:label` (SwiftUI style: `.primary`) | Primary text |
| `textSecondary` | `ripul.textSecondary` | `system:secondaryLabel` (style: `.secondary`) | Detail lines |
| `textTertiary` | `ripul.textTertiary` | `system:tertiaryLabel` (style: `.tertiary`) | Timestamps, hints |
| `textQuaternary` | `ripul.textQuaternary` | `system:quaternaryLabel` (style: `.quaternary`) | The faintest marks, and quaternary fills |
| `separator` | `ripul.separator` | `system:separator` | Hairlines |
| `success` | `ripul.success` | `system:systemGreen` | Online, done |
| `warning` | `ripul.warning` | `system:systemOrange` | Waiting, caution |
| `danger` | `ripul.danger` | `system:systemRed` | Errors, destructive actions |
| `info` | `ripul.info` | `system:systemBlue` | A notice that is not the accent |
| `neutral` | `ripul.neutral` | `system:systemGray` | Inactive, disabled, a grey mark |

`textQuaternary`, `info` and `neutral` are additions to the plan's first list.

## Type roles

| Role | Default |
|---|---|
| `largeTitle`, `title`, `title2`, `title3`, `headline`, `body`, `callout`, `subheadline`, `footnote`, `caption`, `caption2` | The system text style of the same name, family `text` |
| `display` | `title`, family `display` |
| `eyebrow` | `subheadline`, semibold, family `text` |
| `code` | `body`, family `code` |

Three families: `text`, `display`, `code`. Any role or fixed size can be asked
for in another family with `family:`.

## Ripul's theme document

**Path:** `theme/ripul-theme.json` at the repository root. One file for native
and web. The native app bundles it; the web build reads the same file.
`theme/ripul-theme-loud.json` is a test document (see "The loud document"), and
`theme/ripul-theme-brand.json` a trial of the brand (see "The brand document").

**Shape.** Every key is optional. An absent key means "today's look": the
default written in code on that platform. The default document sets nothing.

```json
{
  "schema": 1,
  "name": "Ripul",
  "palette": {
    "teal": { "light": "#1f6f70", "dark": "#62b9b4" },
    "ink": "#1b2a41"
  },
  "roles": {
    "ripul.accent": "teal",
    "ripul.text": "system:label"
  },
  "typography": {
    "families": { "text": "system", "display": "system", "code": "system-monospaced" },
    "roles": {
      "eyebrow": { "family": "text", "size": 15, "weight": "semibold",
                   "relativeTo": "subheadline", "tracking": 0, "uppercase": true }
    }
  }
}
```

(The values show the grammar. They are not the default document.)

| Key | Holds |
|---|---|
| `schema` | `1`. A reader ignores keys it does not know. A document with a higher number is refused whole and the theme in use stays |
| `name` | A label for people |
| `palette` | Named colours. Name to a **colour value** |
| `roles` | Colour roles. Role name to a **reference** |
| `typography.families` | The three families: `text`, `display`, `code` |
| `typography.roles` | Type roles. Role name to an object, every field optional |

**Colour value**: a string, or an object `{ "light": <string>, "dark": <string> }`.
Each string is one of:

- `#RRGGBB` or `#RRGGBBAA` (the `#` is optional);
- `system:<name>`: a platform system colour, live (it follows light, dark,
  increased contrast and elevation). The web has no system colours: a web
  reader treats a `system:` value as absent and uses its own default.

A light and dark pair exists only in `palette`, so `roles` is a flat map of
strings. A pair has no increased-contrast or elevated variant.

**Reference** (the value of a role): a string that is, tried in this order,

1. a palette name (`"teal"`),
2. another role's name (`"ripul.accent"` or `"accent"`), followed until it ends,
3. a literal colour string as above.

A reference that leads nowhere, or round in a circle, gives the role's default
in code. Nothing resolves to magenta.

**Role names** are written `ripul.accent` in Ripul's own document. The reader
also accepts `accent`.

**Families**: `"system"`, `"system-serif"`, `"system-rounded"`,
`"system-monospaced"`, or the name of a font family the app bundles.

**Type role object**:

| Field | Meaning | When absent |
|---|---|---|
| `family` | `text`, `display` or `code` | the role's default family |
| `size` | points at the default Dynamic Type size | the system size of `relativeTo` |
| `weight` | `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` | the system weight of `relativeTo` |
| `relativeTo` | the system text style it scales with | the role's default |
| `tracking` | points; applied by `ripulTextStyle` only | 0 |
| `uppercase` | boolean; applied by `ripulTextStyle` only | false |
| `catalystSize` | a fixed size on Mac Catalyst | `size` |

### In another host's document

One rule, one reader (`RipulTheme.adopt(documentData:)`): if the document has
an object under the reserved top-level key `ripul`, that object is the SDK's
part, in the shape above, and the rest of the document is the host's
business. Otherwise the whole document is the SDK's part (Ripul's own file).

```json
{ "colors": { "accent": "12CEA8" }, "semantic": { }, "fonts": { },
  "ripul": { "roles": { "accent": "#12CEA8" } } }
```

The SDK never reads a host's own palette, roles or fonts, and a host's theme
editor never lists the SDK's roles. A build older than this ignores the key.

**Not built:** nothing yet hands a host's document to that reader. A host
that follows a hosted theme decodes its document itself and gives the engine
only its own slice, so a `ripul` section in WAC's hosted theme would be read
by nobody and dropped by the next publish from a phone. Until the three
paths are built (remote apply, bundled load and restored draft reading the
key from the raw data; publish merging it back), the SDK's screens inside
another host show the system look, which is what the plan decided. The key
is reserved so that it can be built without a format change.

## System colour names

For `system:<name>` and for `ripul(system:)`. The AppKit column is what the
name means on macOS, where the Mac host compiles shared code.

| Name | AppKit |
|---|---|
| `tint` (documents only) | `controlAccentColor` |
| `label`, `secondaryLabel`, `tertiaryLabel`, `quaternaryLabel` | `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `quaternaryLabelColor` |
| `placeholderText`, `link` | `placeholderTextColor`, `linkColor` |
| `separator`, `opaqueSeparator` | `separatorColor` (both) |
| `systemBackground`, `systemGroupedBackground` | `windowBackgroundColor` |
| `secondarySystemBackground`, `secondarySystemGroupedBackground` | `controlBackgroundColor` |
| `tertiarySystemBackground`, `tertiarySystemGroupedBackground` | `underPageBackgroundColor` |
| `systemFill`, `secondarySystemFill`, `tertiarySystemFill`, `quaternarySystemFill` | `quaternaryLabelColor` (all four) |
| `systemRed`, `systemOrange`, `systemYellow`, `systemGreen`, `systemMint`, `systemTeal`, `systemCyan`, `systemBlue`, `systemIndigo`, `systemPurple`, `systemPink`, `systemBrown` | the colour of the same name |
| `systemGray`, `systemGray2` to `systemGray6` | `systemGray` (all six) |
| `white`, `black` (`ripul(system:)` only) | `white`, `black` |

AppKit has no grouped backgrounds, fills or numbered greys, so those rows are
its nearest colours, not equals. The Mac host's own screens are not themed.

## Live repaint

A view already on screen changes when a document is adopted, with nothing
written in the view.

How. Each accessor reads an `@Observable` store when it is called. SwiftUI
records that read against the body that made the call and runs the body
again when the store changes. A colour style carries its resolved colour
inside it, so the new body produces a different style.

Proved on 10 October 2026 (iPhone 18 Pro, iOS 27.0, light and dark) with a
probe app linking this package: a view with no state and no inputs, drawn in
a window, a list row, a sheet, a hosting controller that is a theme root and
one that is not. After `RipulTheme.adopt` of the loud document with no other
change:

| Read by the view | Window | List row | Sheet | Rooted hosting controller | Bare hosting controller |
|---|---|---|---|---|---|
| `Font.ripul(.body)`, with a weight, and a fixed size | changed | changed | changed | changed | changed |
| `.ripul(.danger)`, `.ripul(.textSecondary)` (style form) | changed | changed | changed | changed | changed |
| `Color.ripul(.success)` (Color form) | changed | changed | changed | changed | changed |
| `.tint`, `Color.accentColor` | changed | changed | changed | changed | changed |
| Text with no font of its own | changed | changed | changed | changed | not changed |
| A UIKit view that read `UIColor.ripul` once | not changed | not changed | not changed | not changed | not changed |

And every value went back after `RipulTheme.resetToDefaults()`.

What does not repaint by itself, and what to do:

- **UIKit code**: a colour or font read in `makeUIView`, a cell's
  configuration, `viewDidLoad`. Read it again on
  `Notification.Name.ripulThemeDidChange`, or in `updateUIView`. A dynamic
  `UIColor` (a light and dark pair) follows the appearance by itself; it does
  not follow a new document.
- **Anything computed outside a body and kept**: an attributed string built
  and cached by a renderer or a model, a `Canvas` drawing closure's captured
  values, a value computed in an `init`. It changes when it is next rebuilt.
- **Text with no font of its own** in a presented hosting controller that is
  not a theme root. (One embedded as a child of a rooted tree does change.)

The first version of the style looked the colour up when it was drawn, and
did not repaint: SwiftUI resolves a style again only when the style's own
value changes. That is why the style holds its value.

The older contract still works: a view that reads
`@Environment(\.ripulThemeVersion)` is invalidated under a theme root.

## What the root reaches

`ripulThemeRoot()` is on both of the app's window groups, on the content of
`ripulSheet(isPresented:)` and `ripulSheet(item:)`, in
`ripulThemedHostingController`, and on 14 of the SDK's 24 hosting
controllers. It sets the window's tint to the accent, the theme's `body` font
as the default font, and nothing else. With no theme all of them are nil,
which means "inherit", so it changes nothing.

**Measured** (10 October 2026; throwaway apps under `/tmp`; iOS 17.2 and
27.0; light and dark; centre pixel of a square of each style):

- **The accent, with no call-site edit.** Setting `UIWindow.tintColor`
  reaches `.tint`, `Color.accentColor`, `UIColor.tintColor` and button labels
  in a window, a list row, a sheet, a full-screen cover, a popover, a
  presented hosting controller and a child hosting controller. SwiftUI's
  `.tint()` alone does not: `Color.accentColor` stays system blue in a sheet,
  a cover and a popover, and nothing follows in a hosting controller.
- **Text colours cannot come from a root.** A root `.foregroundStyle` changes
  what `.secondary` draws even when given today's label colour (138,138,142
  becomes 128,128,128, because SwiftUI then derives secondary as half the
  root colour), recolours borderless button labels to the text colour, and
  does not reach a hosting controller. Hence the edit at the call site.
- **The style form is the system's style**: `.ripul(.text)`,
  `.ripul(.textSecondary)`, `.ripul(.textTertiary)`, `.ripul(.textQuaternary)`
  and `.ripul(.danger)` against `.primary`, `.secondary`, `.tertiary`,
  `.quaternary` and `.red`, side by side: identical on a plain background, in
  a list row, a section header, a sheet, inside a prominent button, inside a
  small bordered button, on `.glassEffect(.regular)` and on
  `.glassEffect(.clear)`. On `.regularMaterial` and `.ultraThinMaterial` they
  agree to within 1 in one channel, and so do two squares of the very same
  `Color.secondary` there, so that difference is the material's own.
- **System controls under a themed accent and family** (looked at, not
  sampled): toolbar buttons, a toggle's on colour, plain, bordered and
  prominent buttons, a menu's label, a progress bar, a slider, a label's
  symbol, the selected tab and an alert's buttons all take the accent. Text
  in form rows, buttons, menus and toolbar buttons takes the family.
  **Not reached by the family:** a large navigation title, a segmented
  picker's labels, tab bar labels, an alert's title and buttons. Those are
  drawn by UIKit and need its appearance API: a brand-step item.

### Measured again, with Mac Catalyst

A second run on 10 October 2026 (probe app under `/tmp/theme-cat`; iPhone 17
simulator on iOS 27.0, and the Mac idiom on this Mac; light and dark; pixels
read from screenshots). The full table is plan task `t_2f86f3c4bfce`'s report.
It confirms the above for iPhone and adds these.

**Confirmed.** With the default document every colour role, in both forms,
draws the system's pixels on Catalyst in every container, in light and dark,
and under Increased Contrast on both platforms. In a selected `.sidebar` row
on Catalyst the system draws the hierarchy styles in the accent, and the
style form matches it exactly. With no theme the root leaves a Mac user's own
accent colour alone. A second window group with a root takes the tint and
repaints. A text field's cursor and selection follow the accent on iPhone,
its selection on Catalyst.

**On Catalyst the window's tint does not cross a presentation.**

| Place, under a themed accent | iPhone | Catalyst |
|---|---|---|
| `ripulSheet`, `ripulThemedHostingController`, a rooted second window | follows | follows |
| A bare `.sheet`, a popover with no root inside | follows | `.tint` follows; `Color.accentColor` stays the system's |
| A presented hosting controller that is not a root | follows | nothing of the accent follows |
| A window group or a `UIWindow` with no root | does not follow | does not follow |

So on Catalyst a presented view needs a root inside it. A popover's content
has none unless you give it one: `.popover { content.ripulThemeRoot() }`.

**On Catalyst the Mac keeps some of its own accent.** When the user has
chosen an accent colour, `Color.accentColor` stays that colour under a theme,
even in the root window, while `.tint` is the theme's. The checkbox a `Toggle`
becomes and a progress bar stay the system accent under any theme. Toolbar
items stay black. So on Catalyst a `Color.accentColor` site follows the theme
only if it is written `Color.ripul(.accent)`: a brand-step decision, since
that edit is not an identity where the user has chosen an accent.

**`Color(UIColor.tintColor)` as a SwiftUI colour follows on neither
platform.** Write `Color.accentColor` or `.tint`.

**A themed accent colours things that have no colour today.** On iPhone
toolbar buttons go from the label colour to the accent, a swipe action with no
tint goes to the accent (a destructive one too, which is red today), and a
toggle goes from green to the accent. On Catalyst plain and bordered buttons
stop looking like Mac buttons. None of this happens with the default
document. A swipe action tinted with a role in the Color form keeps its role.

**Text the system draws keeps the system font on both platforms:** a
navigation title, segmented labels, tab bar labels, alerts, menu items, swipe
action labels. In an open menu the icons take the accent and nothing else
follows.

**A themed text role in a selected sidebar row** draws the document's colour
and loses the selection treatment the system gives the hierarchy styles.

**Not measured:** on Catalyst an open menu, a context menu, swipe actions and
the insertion-point cursor (the Mac's screen was locked for the run, so
Catalyst controls were read under a forced active appearance and nothing was
clicked); iOS 17 for either later run.

**Hosting controllers that are not theme roots**, because their type is
declared and a wrapped root view would change it: `FloatingPanel`,
`KeyboardAttachedOverlay` (it copies its parent's environment),
`NativeToolStripAnchorController`, `RipulConformanceScreen` (one of two),
`NativeInteractionRenderer`, `NativeTaskRunRenderer`, `NativeTrainRenderer`,
`NativeDeclarativeArtefactRenderer`, and two in `RipulDevAssistantOverlay`.
On iPhone the accent reaches them through their window. On Catalyst it does
not reach one that is presented (the floating panel and the overlays are in
windows of their own, with no root): there, under a themed accent, `.tint` and
`Color.accentColor` stay the system's. Tokens they read repaint on both. Text
with no font of its own misses a themed family in a presented one. In those
files give every `Text` a font, and expect to make them roots before a brand
theme ships on Catalyst.

## Checking your work

All from the repository root.

**1. Rewrite the mechanical cases.**

```bash
python3 ripul-native-app/scripts/rewrite_theme_tokens.py --dry-run <file or directory>
python3 ripul-native-app/scripts/rewrite_theme_tokens.py <file or directory>
```

It rewrites text-style fonts with their weight and chained calls, the
monospaced forms, fixed sizes whose view it can see is a `Text` or an
`Image`, and the hierarchy styles in both forms. It leaves named colours,
mixed ternaries and fixed sizes it cannot place. Its output over the whole
SDK (1,814 lines) compiles for iOS and macOS.

**2. Do the rest by the closed table.**

**3. Lint the diff.**

```bash
python3 ripul-native-app/scripts/rewrite_theme_tokens.py --lint                 # working tree against HEAD
python3 ripul-native-app/scripts/rewrite_theme_tokens.py --lint HEAD~3          # a range
python3 ripul-native-app/scripts/rewrite_theme_tokens.py --lint HEAD -- <path>  # some paths
```

It pairs each removed line with the line that replaced it and accepts the
pair only if every token's default is the value it replaced. It reads a hunk
that removes and adds the same number of lines; where the counts differ it
asks you to pair the lines by hand or mark them.

**4. Compile, before every push.**

```bash
# SDK streams: for the iOS simulator. About 40 s after the first build.
cd ripul-ios-sdk && swift build --scratch-path /tmp/ripul-theme-<stream> \
  --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"

# and once at the end of the stream for macOS:
cd ripul-ios-sdk && swift build --scratch-path /tmp/ripul-theme-<stream>-mac
```

Do not use `-Xswiftc -sdk -Xswiftc ... -Xswiftc -target ...`: that form
builds for macOS whatever it is given. Measured: with a type error placed
inside `#if os(iOS)` it printed "Build complete", and the `--triple` form
reported the error. 151 of the SDK's files are iOS-only.

App streams build the app, with no install and no simulator:

```bash
cd ripul-native-app && DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
  xcodebuild build -project RipulNativeApp.xcodeproj -scheme RipulApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO RIPUL_SKIP_STANDALONE_BUILD=1 -derivedDataPath /tmp/ripul-theme-<stream>-dd
```

`RIPUL_SKIP_STANDALONE_BUILD=1` makes the build bundle the standalone web
interface that is already built and not write it again. Without it every app
build writes `ripul-native-app/StandaloneRuntime/`, and two at once write the
same files. Use it for a compile check only, never for a build you install.

Measured on this Mac (12 cores) on 10 October 2026, from a clean checkout,
each build into its own empty DerivedData:

| Builds at once | The first build | After touching one app file |
|---|---|---|
| one | 79 to 117 s | |
| two | 124 and 126 s | 5 s with nothing changed |
| four | 335 to 340 s each | 18 s each |

So four app streams can each compile before every push: the first build of a
stream is slow when the others start with it, and every one after is seconds.
It runs the app's pre-build steps, the check among them. It reads the
generated project: a stream that adds or removes no file does not run
`xcodegen`. It compiles the working tree, so another agent's unfinished file
in `ripul-native-app` fails your build too: read the error's path before you
look for the fault in your own change.

**5. Run the check on your paths.**

```bash
python3 ripul-native-app/scripts/check_theme_tokens.py --paths <file or directory>...
python3 ripul-native-app/scripts/check_theme_tokens.py --report
python3 ripul-native-app/scripts/check_theme_tokens.py --update S1     # lower your baseline
python3 ripul-native-app/scripts/check_theme_tokens.py --finish S1     # when your count is zero
```

**A count of zero is not proof that a file is clean.** The check counts a
bare name (`.orange`, `.secondary`) inside a style call, in an argument whose
label names a colour (`tint: .blue`, `colors: [.blue, .purple]`), on a line
that says its type is `Color`, and after `return`. A bare name passed to an
unlabelled parameter, or assigned to a property declared elsewhere, it cannot
see. Read your diff for those before `--finish`.

Each stream has its own baseline file in
`ripul-native-app/scripts/theme-baseline/`; edit only yours, and only through
`--update` and `--finish`. The app build runs the check. Until a stream is
finished, a count above its baseline is a warning in the build log. After
`--finish` its baseline is zero and any direct font or colour in its files,
in a new file too, fails the build. `--finish` refuses while anything is
left, other agents' additions included: clear those too.

Streams by path: `F` the foundation's five files; `S1` `Sessions/`; `S2`,
`S3`, `S4` the SDK's top-level files A to M, N to S, T to Z; `S5` the SDK's
other subdirectories; `A1`, `A2`, `A3` `ripul-native-app/iOS` A to L, M to R,
S to Z; `A4` `Shared/` and `Browser/`. Not counted: `CmsRender/`,
`ThemeCore/`, the theme editor's screens (`Theme*.swift`,
`Element*Screens.swift`), the View Explorer overlay (`RipulViewExplorer.swift`,
`ViewInspectorOverlay.swift`), `iOS/CarPlay/`, the widgets, the Mac host,
`Sources/RipulCommands/`, and any branch that compiles only for macOS
(`#if os(macOS)`, `#elseif os(macOS)`, the `#else` of `#if os(iOS)` or of
`#if canImport(UIKit)`). The rewrite script leaves those branches alone too.

**6. At the end of the stream, the reference screens.**

```bash
ripul-train acquire simulators os=27.0 type=iPhone booted=false --reason "theme <stream>: reference screens" --json
python3 ripul-native-app/scripts/ship_duo_sim.py --simulator <udid> --no-launch
python3 ripul-native-app/scripts/theme_reference_screens.py capture --simulator <udid> --out /tmp/theme-ref/<stream>
python3 ripul-native-app/scripts/theme_reference_screens.py compare ~/.ripul/theme-reference/baseline /tmp/theme-ref/<stream>
ripul-train release <lease>
```

Use a simulator with no account signed in. The baseline is on this Mac, not
in git: `~/.ripul/theme-reference/baseline` is fourteen screens in four
conditions, captured by S1 from `2a6c772dd`, before any stream's files were
touched, after a simulator restart, with the session-list fixtures and with no
system alert over any of them. The two earlier baselines beside it
(`baseline-foundation`, `baseline-s1`) hold captures covered by the
notification-permission alert: do not compare against them. `capture` now
restarts the simulator first and has no signed-out screen, which is what
raised that alert. Look at a few of your captures before you trust a
comparison: two covered pictures compare as identical.

## The loud document

`theme/ripul-theme-loud.json`: every colour role a different saturated
colour, three different families, every type role a different size. In a
Debug build of the app:

- launch argument `-ripul.theme.document ripul-theme-loud`, or
- open `ripul://theme?name=ripul-theme-loud` (and `name=ripul-theme` to go
  back). The choice is kept between launches.

A view that does not change has a call site the migration missed; a view in
the wrong loud colour has the wrong role. A Release build ignores the choice.

## The brand document (a trial)

`theme/ripul-theme-brand.json` is a first look at the website's brand, chosen
exactly as the loud document is (`-ripul.theme.document ripul-theme-brand`, or
`ripul://theme?name=ripul-theme-brand`), in a Debug build only. It is not the
default and not the finished brand step.

| It sets | To |
|---|---|
| `ripul.accent` | the website's teal: `#1f6f70` light, `#62b9b4` dark |
| `ripul.onAccent` | white in light (5.89 to 1 on the teal); the website's ink `#23253a` in dark (6.53 to 1), where white is 2.30 to 1 and fails |
| the `text` family | `Archivo` |
| the `display` family | `Instrument Serif` |
| `display` | 36 points (28 on Mac Catalyst) |
| `eyebrow` | semibold, capitals, 1.8 points of tracking (the website's 0.14 em at 13 px) |

It sets no canvas, surface or text colour, and no size but the display
role's, so each other style keeps the platform's own size.

**The fonts** are in `theme/fonts/`, copied into the app as the folder `fonts`
and registered at launch by `RipulAppTheme.registerFonts()` in every build.
`theme/fonts/SOURCES.md` says where each file came from; the licences are
beside them.

**Measured on 10 October 2026** (a macOS probe that registers the files and
draws with SwiftUI; then looked at in the simulator):

- Archivo is one variable file. `Font.custom("Archivo", ...)` takes
  `.weight()`: light, regular, medium, semibold and bold each draw more ink
  than the last, and `.bold()` equals `weight: .bold`. `heavy` draws as black.
- Archivo has fixed-width digits (`tnum`): under `.monospacedDigit()` ten ones
  and ten zeros are the same width; without it they differ by 8 per cent.
- Instrument Serif is regular and italic only. `.bold()` on it draws the
  regular: the system does not fake a bold.

It gives the `display` role a size (36 points, 28 on Mac Catalyst): Instrument
Serif has one weight, so the title carries by size where a bold 28 point
sans did.

**The display role is read in one place:** the four onboarding titles
(`OnboardingView.swift`). `ripulTextStyle(.eyebrow)` is used nowhere yet, so
the eyebrow's tracking shows nowhere.

## The View Explorer

Select an element in the View Explorer and its Appearance section names the
theme tokens that style it: each colour role with a swatch, each type role
with its face and size, and for both whether the value is the default or
comes from the theme document. The same lines are in the explorer's text
readout (Copy, and the `explorer_probe` device tool) under `appearance:`.

Nothing registers this and no call site declares anything. The identifier and
the accessor were already in the source.

**How it knows.** SwiftUI draws into layers, so the view that was tapped holds
no colour and no font. `ripul-native-app/scripts/theme_usage_map.py` reads the
source at build time: every `.uiKitIdentifier("…")` and
`.accessibilityIdentifier("…")`, and the accessors in the view expression it
ends. The app's Debug build writes the result into the bundle as
`ripul-theme-usage.json`, and `RipulBaseTokenProvider` (SDK) looks the selected
element's identifier up in it and resolves each token against the live theme.

For an identifier it records the accessors:

| Found | Shown as |
|---|---|
| in the element's own expression | `Foreground` |
| on a `.font(…)`, `.foregroundStyle(…)`, `.foregroundColor(…)` or `.tint(…)` applied to a view that encloses it in the same function | `Font (from an enclosing view)` |
| through a `Font` or `Color` property of the same type, or a local `let` | `Font (in titleFont, one of several)` |
| inside a view type, a view-returning member or a `View` extension modifier that the expression names, two steps deep | `Foreground (in SessionTitleLozenge)` |

A font or colour written on the element that is not a token (a model's
colour, a material, a value passed in) is listed as "not a theme token" with
the source text, so that no token is never read as nothing sets it.

**What the system draws, where it is not what the source writes.** A text
role's default is the system's hierarchical style, and inside a `Button`, a
`Menu` or a `Link` that style is a step of the control's own foreground, which
is its tint. So the top bar's buttons write `.foregroundStyle(.ripul(.text))`
and are drawn in the accent (seen on the phone under the brand document: the
chevron is the teal). The map marks every accessor that sits inside such a
control, with any `.buttonStyle` chained to it, and the section then shows:

| The source | The section says |
|---|---|
| a default text role, style form, in a control with no button style | `ripul.accent, as the system draws it`, the accent's value and swatch, and that the source writes the text role |
| the same under `.buttonStyle(.plain)`, or in the Color form, or a role the theme names | the role as written |
| the same under another button style | the role, "a step of the control's own label colour", and no swatch |
| the same in a toolbar with no themed accent | the role, and that it becomes the accent once a theme names one |
| a control with no foreground written at all | "the system colours it": usually the accent, and no swatch, because a menu or a toolbar draws it otherwise |
| a control that is an item of a menu, a context menu, swipe actions, an alert or a dialog | the role, "the system's own colour for a menu item", and no swatch |
| a `Toggle` | its on colour: the system's green, and the accent once a theme names one |

A button style set by a view around the control, in another function, is not
seen, and each of these lines says so.

**Checked against pixels** on 11 October 2026 (iPhone Duo simulator, iOS 27.1,
the Agents screen; the app's own frame at one pixel a point, the strongest ink
in each element's box):

| Element | The section says | Default, light | Brand, light | Brand, dark |
|---|---|---|---|---|
| top bar menu button (`.ripul(.text)` in a `Button`) | the accent | blue `#3472AD` | teal `#2D5556` | teal `#8AB7B4` |
| top bar "…" (`.ripul(.text)` in a `Menu`) | the accent | blue `#2579C7` | teal `#2A5E5E` | teal `#7EB6B0` |
| new-session "+" in the bar (no foreground, toolbar) | label colour, then the accent | black | teal `#205957` | teal `#98D1CE` |
| "New Chat" pill (plain button, no foreground in that branch) | "one of several" | black | black | white |
| "18 more" (plain button, `textSecondary`) | `ripul.textSecondary` | grey `#7D7D7D` | grey `#7F7F7F` | grey `#8F8F8F` |

The accent's own values are `#0088FF`, `#1F6F70` and `#62B9B4`: a thin symbol
on glass at one pixel a point reads darker or lighter than its colour, so the
hue is what these prove, not the value. On the phone at three pixels a point
the same button measured `#57B5AA` against `#62B9B4`.

A token written in one branch of an `if` or a `switch` inside the element is
"one of several", like one side of a ternary. A swatch's hex is `#RRGGBBAA`
when the colour is not opaque (the system's secondary label is 60 per cent).
Where the nearest identifier is the whole screen's, nothing is listed.

An accessor inside a part that has its own identifier belongs to the part.
An identifier with an interpolation (`"row.\(id)"`) is kept as a pattern.

**A view with no identifier** gets the tightest identified element around it,
and the section says which one it used.

**A UIKit view** (a navigation title, a label in a cell) holds its font and
colour, so they are read off the view and compared with the roles. A match is
shown as "the same colour as this role": it says what the view holds, not what
the code wrote.

**When nothing can be named** the section says why: the view has no identifier
and nothing identified is around it; the identifier is not in the map (set in
UIKit, held in a variable, or in another package); the element's source names
no token; or the build carries no map.

**Another host's provider is not replaced.** `RipulTokenInspector.provider` is
asked first, and its answer stands alone when it has one. The base vocabulary
answers only where the host has nothing to say, and inside such a host it
answers from the map only, never by matching a UIKit view's colours. A host
turns it off with `RipulTokenInspector.answersForBaseVocabulary = false`.

**Limits.**

- It reads text, it does not compile. A colour passed in as a parameter, a font
  set by a caller in another type, and an identifier held in a variable (40 of
  1,529 on 11 October 2026) are not seen. On that day 875 identifiers named at
  least one token and 44 more had only a font or colour that is not a token.
- It says what the source can draw, not what is on screen now: where the code
  chooses between roles, each is listed as "one of several".
- Text with no font written on it or around it is reported as taking the
  root's default font. That is reasoned from `ripulThemeRoot()`, not read.
- The explorer does not resolve an element drawn in the keyboard's overlay (the
  chat composer's buttons): it finds only the screen's identifier, and the
  section says so.
- Only an app whose build runs the script has a map. A host that does not sees
  the SDK's own screens without tokens, and the section says the map is missing.
- Debug builds only.
- Reading only. The explorer cannot change a base token: see Limits.

```bash
python3 ripul-native-app/scripts/theme_usage_map.py --stats
python3 ripul-native-app/scripts/theme_usage_map.py --explain AgentScreen.topBar.leadingButton
python3 ripul-native-app/scripts/theme_usage_map.py --roots <an app's source directories> --out <file>
```

The tests are `Tests/RipulAgentTests/RipulThemeUsageTests.swift`.

## For the theme's owner

```swift
try RipulTheme.adopt(documentData: data)   // a whole document; throws and changes nothing if it is refused
RipulTheme.resetToDefaults()               // back to the system look
RipulTheme.color(.accent)                  // the resolved value, light and dark
RipulTheme.isDefault(.accent)
```

The app does this in `ripul-native-app/iOS/RipulAppTheme.swift`. The base
vocabulary is separate from the host engine (`RipulThemeEngine`): a host's
`configure` does not touch it.

In the host engine, additive and for any host: a palette entry may be a light
and dark pair (held in `RipulThemeDocument.primitivesDark`, so `primitives`
stays a map of strings), and a colour reference may be `system:<name>` or
`#RRGGBBAA`.

## Limits

- **The theme editor cannot edit these tokens.** It writes one hex over a
  pair and cannot choose a system colour or a font. A look is tried by
  loading a document. There is no list of documents in the app's settings:
  the switch is the launch argument and the URL above.
- **The widgets and the Live Activity** do not link the SDK and are not
  themed.
- **A custom family and Dynamic Type.** A themed role with a size uses
  `Font.custom(_:size:relativeTo:)`, which scales on a slightly different
  curve from the system's at accessibility sizes.
- **Mac Catalyst type.** The text-size setting does nothing on Catalyst. A
  role with a `size` and no `catalystSize` is drawn at that size, which is an
  iPhone size (18 against a 13 point system body, measured), so a brand
  document needs a `catalystSize` for every role it sizes. A family with no
  sizes is drawn at the platform's own size for each style (13 for body on
  Catalyst): that was 17 when measured and was corrected afterwards, and the
  correction is reasoned, not rerun on Catalyst. The reference screens do not
  capture Catalyst.
- **A sized role in a system face, and `UIFont.ripul`,** follow the real
  text-size setting only, not a local `.dynamicTypeSize` or a trait override.
- **Reference screens** cover what a signed-out install can show: the start
  chooser, the standalone workspace and nine developer fixtures. No session
  list, chat or settings screen is in them, because nothing loads fixture
  data for those. Reduce Motion is not set.
