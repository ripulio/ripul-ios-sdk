# A theme for your app

This page is for an app that links the RipulAgent package, or only its theme
product `RipulThemeKit`, and wants its own fonts and colours to come from a theme: one JSON document, light and dark,
switchable while the app runs. It starts from "add the package" and is in the
order to do the work. The full contract, with every measurement behind a rule
here, is [theming.md](theming.md); you should not need it to get through this
page.

What you write, in total: one line at the root, a theme document, your font
files, one line of build setup for the View Explorer, and whatever the
migration command leaves for a person to decide. Everything else is the SDK's.

Where a thing is not built, this page says so. The list is at the end.

**If an agent is doing the work,** give it the procedure first: what to measure
before the first edit, which level to start at, where to stop and ask, and how
to prove nothing moved. It is a skill file in this package,
`tools/skills/theme-an-app/SKILL.md`, and one command copies it to where a
coding agent in your repository finds it (`.claude/skills` for Claude Code,
`.agents/skills` for Codex):

```bash
<the package checkout>/tools/ripul-theme install-skill <your repository>
```

An agent running inside Ripul reads the same text as the `theming` guide of its
`ripul_guide` tool. This page is the reference that procedure points to.

## The idea

Every token has a default that is the system value you write today.
`Font.ripul(.body)` is `Font.body`. `.ripul(.textSecondary)` is the system's
`.secondary` style. So moving a call site to a token changes no pixel, and an
app with no theme document looks exactly as it did. A document changes a token
only by naming it.

## With no change to your source

There are two ways to adopt the theme. The numbered steps below are the first:
you move your call sites to tokens, with a command that does most of it. This
section is the second: you change settings and add files, and no line of your
Swift changes. It is in the package from release 0.7.172; from 0.7.174 it
also reaches text with no colour, lists and your own colours; and from 0.7.175
markdown and every other kind of text, a label's title, a prominent button's
label and a navigation title's colour. From 0.7.176 a window's root draws the
canvas, and the migration's own lines leave a view untouched until a theme
names its colour. It has been measured on one app. It is where to start: the numbered steps are for an app
that wants what this does not reach.

What you do:

1. Add the package to the app target, as in step 1 below, without the root
   line. An app that wants the theme and nothing else links the product
   `RipulThemeKit` in place of `RipulAgent`: see "Shipping only the theme".
2. Put your theme document and font files in the bundle (steps 2 and 3).
3. Switch on the package's build-tool plug-in, `RipulThemeRedirect`, for the app
   target: in Xcode, the target's Build Phases, "Run Build Tool Plug-ins", add
   it. In an XcodeGen `project.yml`:

   ```yaml
       buildToolPlugins:
         - plugin: RipulThemeRedirect
           package: RipulAgent
   ```
4. Allow the plug-in to run. Xcode asks once, "Trust & Enable". A command-line
   build passes `-skipPackagePluginValidation` to `xcodebuild`; without it the
   build fails with the one line `Validate plug-in “RipulThemeRedirect” in
   package “ripul-ios-sdk”` (measured with the package fetched by version; a
   package added by local path needs neither). Add the flag to your build
   scripts too.

With one theme document in the bundle, that document is the app's theme. With
several, name one with the Info.plist key `RipulTheme`.

**How it works.** On every build the plug-in writes one Swift file into the
build folder, and Xcode compiles it into your app's own module. The file
declares SwiftUI's names again: `Font.body` and the other text styles,
`Font.system(size:)`, `Color.red`, `Color(.systemBackground)`, `Color("Name")`,
`.foregroundStyle(.secondary)`, `Text("…")`, `List`, `Form`, `Section`,
`WindowGroup`. Inside your module your
declaration of a name is chosen over SwiftUI's, so your existing `.font(.body)`
calls the generated one, which is one call into the SDK. With no theme each
returns exactly what SwiftUI's would have. Nothing is added to your repository.

**What it reaches,** with no edit:

| You wrote | It follows |
|---|---|
| `.font(.body)`, `.font(.caption.weight(.semibold))`, `Font.body` | the type role of that name |
| `.font(.system(size: 14, weight: .medium))` | the text family at that size |
| `.system(.title, design: .serif)`, `.system(size: 22, design: .serif)`, and your own helper built on them | the display family, once a theme names one; the system's serif until then, with no second document |
| `design: .monospaced` | the code family |
| a font on an `Image` | nothing: a symbol keeps its system size |
| `.foregroundStyle(.secondary)` and the other hierarchy styles | the text roles |
| `Color(.systemBackground)`, `Color(.systemGroupedBackground)`, `Color(.secondarySystemGroupedBackground)` | `canvas`, `surfaceSunken`, `surface` |
| `Color.red`, `.foregroundStyle(.orange)`, green, blue, gray | `danger`, `warning`, `success`, `info`, `neutral` |
| `Color("BrandNavy")`, a colour of your asset catalogue | a role of that name, once a document names it (step 2, "Your own colours") |
| a `Text` with no colour of its own, however it is made: `Text("…")`, `Text(aString)`, `Text(anAttributedString)` and so markdown, `Text(verbatim:)`, `Text(date, style:)`, `Text(value, format:)` | the `text` role. The build reads your source for each such text and the generated file carries their lines, so a new text is themed without anyone adding it |
| the title of `Label("Title", systemImage: …)` or `image:` with no colour of its own | the `text` role. Its icon is left as the system draws it |
| `.buttonStyle(.borderedProminent)` and `.glassProminent` on a button with no `.tint` of its own and none from a view round it | the label in `onAccent`. A button you tint yourself keeps the system's white label: its fill is your colour, not the theme's accent |
| a navigation title, large and inline | the `text` role, beside the text family |
| `List { … }`, `Form { … }` | the ground in `surfaceSunken`, the rows in `surface`, the separators in `separator` |
| `Section("Title") { … }`, `Section { … } header: { … } footer: { … }` | the header and footer in the text family and in `textSecondary` |
| `WindowGroup { … }` | the theme root, with no line written: the accent, the body font for text with none, navigation titles, tab bar labels |
| identified elements | the View Explorer names their tokens (Debug builds), with no build phase |

**Which texts count as having no colour.** One that has no `foregroundStyle`
or `foregroundColor` in its own chain of modifiers, none on a view round it in
the same file, and is not coloured by the system: not inside a `Button`,
`Link`, `Menu`, `Picker`, a toolbar, an alert, a section's header or footer, a
`LabeledContent` or an empty state. A button or link with
`.buttonStyle(.plain)`, and a navigation link that is a row of a list, leave
their label the text colour, so a text there counts. A view of your own that
is coloured where it is used (`Wordmark().foregroundStyle(.white)`, or inside
a stack that has a colour, or as an unstyled button's label) is followed
across files: its texts are left alone. To see the list:
`ripul-theme check --text <your source folder>`.

**What it does not reach.** These stay the system's under a theme:

- a text made a way the generated file does not declare again: a date range
  or a timer, `Text(a) + Text(b)`, a `Label { … } icon: { … }` whose title is
  not a `Text` written there, and a `TextField`'s text;
- a text coloured through something the build cannot see: a view kept in a
  property and coloured where the property is used, a `ViewModifier` or a
  style of your own that colours its content. Such a text is themed where it
  took the container's colour before. Look at each screen under the theme;
- a `List`, `Form` or `Section` written in a form the generated one lacks
  (`List($items)`, `children:`, `Section(isExpanded:)`, a `Table`): the build
  log names it and SwiftUI's own is used for that name in the whole target;
- a row's swipe actions and selection highlight, which stay the system's, and
  a `Section` inside a `Picker` or a `Menu`, whose header takes the family;
- the label of a prominent button you tint yourself, as above;
- a hierarchy style given to `fill`, `stroke` or `background`, and one passed
  through a variable of a generic type;
- white and black, and a colour of your own that is not read as
  `Color("Name")` (step 2, "Your own colours");
- UIKit code (`UIFont.preferredFont`, `UIColor.label`);
- a `Label`'s icon, which takes its size from the label's font as before.

**What can go wrong.**

- A name you already declare (`extension Font { static var caption }`, a type
  called `WindowGroup`) is left out of the generated file and yours is used.
  The generator reads text, not types; one it misses is a compile error naming
  both places.
- A target is redirected only if the plug-in is on for it. A framework of your
  own needs it switched on too.
- `WindowGroup(for:)` and a UIKit app delegate are not covered: put
  `.ripulThemeRoot()` on the root yourself and add `RIPUL_THEME_NO_ROOT` to the
  target's Swift compilation conditions. `RIPUL_THEME_NO_STYLES` leaves
  `foregroundStyle` alone, `RIPUL_THEME_NO_TEXT` leaves `Text` and `Label`,
  `RIPUL_THEME_NO_LISTS` leaves `List`, `Form` and `Section`, and
  `RIPUL_THEME_NO_BUTTONS` leaves the prominent button styles.
- A `List`, `Form` or `Section` in your own files is the generated type, not
  SwiftUI's. Used as a view it behaves as SwiftUI's does; a line that names
  the type (`let list: List<Never, Text>`) must say `SwiftUI.List`.
- The lines of your bare texts are read when the app is built. A text on a
  line that also holds a coloured text is left alone: put each on its own line.
- A font or colour kept in a `static let` is read once and does not follow a
  switch while the app runs.
- The rule this rests on, that a module's own declaration is preferred to an
  imported one of the same name and type, is how the Swift compiler behaves
  (measured with Swift 6.4, Xcode 27.1, in Swift 5 and Swift 6 language
  modes). The language's documentation does not promise it. `Text` leans on
  two more. Of two initialisers that both fit, the one whose first parameter
  is the closer match is chosen, and SwiftUI's string form is marked as the
  one to avoid, so the generated one is marked the same way
  (`@_disfavoredOverload`, an attribute the compiler has and does not
  document). And where SwiftUI has an exact match (`Text(verbatim:)`, an
  attributed string, a date, a format, a label), the generated file declares
  that exact form again, marked as the one to avoid, which hides SwiftUI's and
  lets the form that carries the line be chosen.

The two ways mix: a file you have migrated calls the accessors directly, and
the rest goes through the generated file.

## Shipping only the theme

The package has two library products. `RipulAgent` is the whole SDK: the
developer console, the View Explorer, the agent. `RipulThemeKit` is the theme
alone: the roles, the accessors, the root, the document loader, font
registration, the picker and what the plug-in's generated file calls. It has
no dependencies. `RipulAgent` contains it and passes it on, so a file that
imports `RipulAgent` needs nothing else. It is in the package from 0.7.174.

Measured on one app (a guide of 16 Swift files, Release, for a device, the
theme by the plug-in, unsigned):

| The app links | Executable | App folder |
|---|---|---|
| `RipulAgent` | 64,952,304 bytes | 77,448 KB |
| `RipulThemeKit` only | 2,358,480 bytes | 15,956 KB |
| both, with `RipulAgent` left out of Release (below) | 4,782,512 bytes | 18,696 KB |

The same app with no package at all is not in the table: its photos, fonts and
own code are about 15.5 MB of the app folder in every row.

**An app that wants only the theme** links `RipulThemeKit`. In an XcodeGen
`project.yml`:

```yaml
    dependencies:
      - package: RipulAgent
        product: RipulThemeKit
```

In Xcode: the target's General tab, Frameworks and Libraries, add
`RipulThemeKit` and remove `RipulAgent`. Source that calls the accessors
imports `RipulThemeKit`.

**An app that also has the developer console in its Debug builds** links
both, and leaves the whole SDK's code out of Release with one build setting:

```yaml
    dependencies:
      - package: RipulAgent
        product: RipulThemeKit
      - package: RipulAgent
        product: RipulAgent
    settings:
      configs:
        Release:
          EXCLUDED_SOURCE_FILE_NAMES: "RipulAgent.o"
```

Everything of yours that uses `RipulAgent` must then be inside `#if DEBUG`, or
the Release build fails to link, naming what it could not find. The setting
is Xcode's own. It leaves out the SDK's object file. The SDK's three
dependencies are still linked and two small resource bundles still copied
(372 KB), which is the difference between the last two rows. Writing
`"RipulAgent*"` drops those bundles too, and with them the theme's own privacy
manifest: do not.

**What a store build then holds** (measured: a Release archive of that app
with both products and the setting above, exported with a development
signature, nothing uploaded): the app's own code and files; the theme module;
and three resource bundles, of which `RipulAgent_RipulThemeKit.bundle` holds
the theme's privacy manifest and the other two (`RipulAgent_RipulAgent`,
`HighlightSwift_HighlightSwift`, 372 KB together) are the SDK's own, unused
without its code. An app that links `RipulThemeKit` alone has only the first.
The manifest declares the one reason-required API the theme uses,
`UserDefaults`, where the person's choice of theme is kept (reason CA92.1).
Nothing of the developer tools is in the binary (no string of theirs is
found in it), and the check for private Apple functions is clean: the theme
module uses none. The archived executable was 2,074,704 bytes, the app
16,108 KB and the IPA 13.1 MB. Not run: an export signed for the App Store, an
upload, and App Store Connect's own validation.

## 1. Add the package and name your theme

Pin the package (`https://github.com/ripulio/ripul-ios-sdk`), then put one
modifier on the root view of each window group:

```swift
import RipulAgent

WindowGroup {
    ContentView()
        .ripulThemeRoot(theme: "brand")     // brand.json in the app's bundle
}
```

That line is the whole setup. From it the SDK:

- finds `brand.json` in the bundle (at its top level, or in a folder named
  `Themes` or `Theme`), reads it and puts it in use before the first view is
  drawn;
- registers the font files the document names (step 3);
- keeps a choice made with `RipulTheme.select` between launches (step 6);
- falls back to `brand`, and then to the system look, when a document is
  missing, is not a theme document, or was written for a newer SDK. It logs
  which, with the prefix `[RipulTheme]`.

Two other ways to say the same thing, for an app that cannot put it on a root:

- the Info.plist key `RipulTheme` with the document's name, and a plain
  `.ripulThemeRoot()`;
- `RipulTheme.install(theme: "brand")` in the `App`'s `init` or the app
  delegate, for a UIKit app.

With no name at all, `.ripulThemeRoot()` leaves the app on the system look.

**The canvas.** The root that names the theme is a window's own root, and
under a theme that names `canvas` it draws that colour behind everything, so
a screen with no ground of its own (an empty state, a plain stack, a start
screen) stands on the theme's ground and not on the system's white or black.
A root you write without a name does the same when you say it is a window's:
`.ripulThemeRoot(window: true)`. Leave that off the root of a sheet, a popover
or an overlay: those have a ground already, or are meant to be seen through.

The root carries the accent (as the window's tint, so `.tint`,
`Color.accentColor` and control tints follow with no edit) and the theme's
body font for text with no font of its own. A sheet presented with
`.ripulSheet` has a root already. A presented `UIHostingController` of your
own needs `.ripulThemeRoot()` on its root view.

## 2. Write the document

Every key is optional, and an absent key is today's look. Start with
`{ "schema": 1, "name": "Brand" }`, which changes nothing, and add to it.

```json
{
  "schema": 1,
  "name": "Brand",
  "palette": {
    "navy":  { "light": "#24386b", "dark": "#a9bdeb" },
    "paper": { "light": "#f7f3ec", "dark": "#0d1428" },
    "ink":   "#1c2540"
  },
  "roles": {
    "ripul.accent": "navy",
    "ripul.canvas": "paper",
    "ripul.text": "ink"
  },
  "typography": {
    "families": { "text": "Source Sans 3", "display": "Playfair Display", "code": "system-monospaced" },
    "roles": {
      "display": { "size": 34, "weight": "bold" },
      "eyebrow": { "tracking": 1.8, "uppercase": true }
    }
  }
}
```

- **`palette`** names your colours. A value is `#RRGGBB`, `#RRGGBBAA`,
  `system:<name>` (a live system colour such as `system:label`), or a light
  and dark pair of those. Light and dark are written here and nowhere else.
- **`roles`** gives each colour role a palette name, another role, or a colour
  string. The fifteen roles, each with the system colour it is by default:

  | Role | Default | For |
  |---|---|---|
  | `accent` | the app's tint | selection, links, primary buttons |
  | `onAccent` | white | text and icons on an accent fill |
  | `canvas` | `systemBackground` | the app's background |
  | `surface` | `secondarySystemGroupedBackground` | cards and grouped rows |
  | `surfaceSunken` | `systemGroupedBackground` | the ground behind cards |
  | `text`, `textSecondary`, `textTertiary`, `textQuaternary` | `.primary` to `.quaternary` | text |
  | `separator` | `separator` | hairlines |
  | `success`, `warning`, `danger`, `info`, `neutral` | green, orange, red, blue, grey | state |

  An app adds roles of its own to these: see "Your own colours" below.
- **`typography.families`** names the three families, `text`, `display` and
  `code`. Each is a font family you bundle, or one of `system`,
  `system-serif`, `system-rounded`, `system-monospaced`.
- **`typography.roles`** changes a type role: `size`, `weight`, `family`,
  `relativeTo`, `tracking`, `uppercase`, `catalystSize`. The roles are the
  eleven system text styles by their own names, plus `display` (a title in
  the display family), `eyebrow` and `code`.

**A serif that is yours already.** `"display": "system-serif"` draws what
`.font(.system(.title, design: .serif))` draws (compared pixel for pixel in a
host's trial on iOS 27, at the default text size). There is no accessor for
`design: .serif` itself. So an app whose headings are serif today keeps them
by naming `system-serif` as its display family and writing
`.font(.ripul(.title, family: .display))` at those headings. Its document is
then not empty, and the plain system look (`RipulTheme.systemThemeName`) is
not the look it had.

Check a dark value against its background yourself: nothing checks contrast.

### Your own colours

An app has a few colours that are its brand and are none of the fifteen: a navy
that is not the accent, a cream. Each becomes a role of your own, with the
colour it is today as its default, so nothing changes until a theme names it.

**With the plug-in, nothing to write.** `Color("BrandNavy")`, a colour of your
asset catalogue, is a role named `BrandNavy`. Name it in the document:

```json
  "roles": {
    "ripul.accent": "navy",
    "BrandNavy": { "light": "#24386b", "dark": "#5b78c4" }
  }
```

A role's value is a palette name, another role, a colour string, or (for a role
of your own or one of the fifteen alike) a light and dark pair written in place.
Until a document names `BrandNavy`, `Color("BrandNavy")` is the asset, itself.
Not reached this way: `UIColor(named:)`, a colour from another bundle, and the
generated symbol form `Color(.brandNavy)`.

**In source you have migrated, declare the role once** and read it with the
same accessors as the fifteen:

```swift
extension RipulColorRole {
    static let navy = RipulColorRole(asset: "BrandNavy")                          // named for its asset
    static let cream = RipulColorRole("cream", default: "#F4EBDD", dark: "#2A2418")
}

Text("Sandsend").foregroundStyle(.ripul(.navy))
Rectangle().fill(Color.ripul(.cream))
view.backgroundColor = .ripul(.navy)
RipulTheme.isDefault(.navy)        // true until a theme names it
```

A default is `#RRGGBB`, `#RRGGBBAA`, `system:<name>` or `asset:<name>`. The
tools read the declarations: `migrate` rewrites `Color("BrandNavy")` to
`Color.ripul(.navy)`, `lint` takes the two as one value, `check` counts a
`Color("BrandNavy")` that goes round a declared role, and the View Explorer
names the role with its value and whether the document set it.

- A role's name in the document is the name you gave it (`BrandNavy`, `cream`).
  The fifteen keep theirs, and a role of yours cannot take one of them.
- Do not keep the colour in a `static let` (`static let navy = Color("BrandNavy")`
  is read once and does not follow a switch while the app runs). Keep the role
  in one, as above, and read the colour where it is used.
- A role is known to the SDK from the first time the app reads it. A document
  may point one role at another of yours only once it has been read; point
  both at a palette name instead.

## 3. Fonts

Put the font files in the app's bundle, at its top level or in a folder named
`Fonts`. Do nothing else. When a document names a family that is not the
system's, the SDK reads the bundled `.ttf`, `.otf` and `.ttc` files and
registers those that hold a face of that family. No `UIAppFonts` entry and no
registration call.

- The name in the document is the font's family name ("Source Sans 3"), not
  its file name.
- A variable font takes weights; a family with one weight draws that weight
  whatever is asked, and the system does not fake a bold.
- Ship each font's licence beside it. That is yours to get right.

## 4. Move the call sites: one command

The package brings its tools. In an Xcode project they are in the package
checkout, under the build's DerivedData:

```bash
# with -derivedDataPath build
RIPUL_THEME=build/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme
# with Xcode's default DerivedData
RIPUL_THEME=$(ls -d ~/Library/Developer/Xcode/DerivedData/<Project>-*/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme | head -1)
# in a Swift package
RIPUL_THEME=.build/checkouts/ripul-ios-sdk/tools/ripul-theme
```

They need `python3` and nothing else.

```bash
$RIPUL_THEME migrate --dry-run --named <your source folder>   # what would change
$RIPUL_THEME migrate --named <your source folder>             # change it
```

Every rewrite is to the token whose default is the value it replaces, so
nothing moves on screen. It adds `import RipulThemeKit` to each file it left
calling an accessor, unless the file imports it or `RipulAgent` already or the
app has one `@_exported import` of either. It rewrites:

| You wrote | It writes |
|---|---|
| `.font(.body)`, `.font(.caption.weight(.semibold))` | `.font(.ripul(.body))`, `.font(.ripul(.caption, weight: .semibold))` |
| `.font(.title2)` or `.font(.system(size: 18))` on an `Image` | `.font(.ripulIcon(.title2))`, `.font(.ripulIcon(size: 18))`: a symbol's size, never themed |
| `.font(.system(size: 14, weight: .medium))` on a `Text` | `.font(.ripul(size: 14, weight: .medium))` |
| `.caption.monospaced()`, `design: .monospaced` | `family: .code` |
| `.foregroundStyle(.secondary)` and the other hierarchy styles | `.foregroundStyle(.ripul(.textSecondary))` |
| `Color.primary`, `Color.secondary` | `Color.ripul(.text)`, `Color.ripul(.textSecondary)` |
| `Color(.systemBackground)`, `UIColor.systemBackground`, `UIColor.label` | `Color.ripul(.canvas)`, `UIColor.ripul(.canvas)`, `UIColor.ripul(.text)` |
| any other system colour, `Color(.systemGray5)` | the system form, `Color.ripul(system: .systemGray5)`: drawn as before, never themed |
| `.buttonStyle(.borderedProminent)` | `.ripulProminentButtonStyle()`: its label is drawn in `onAccent` under a theme |
| `.buttonStyle(.glassProminent)` | `.ripulGlassProminentButtonStyle()`, likewise |
| with `--named`: `Color.red`, `.foregroundStyle(.orange)` | `Color.ripul(.danger)`, `.foregroundStyle(.ripul(.warning))` |
| with `--named`: `.white`, `.black`, `.yellow` and the other hues | the system form, `.ripul(system: .white)` |
| with `--text`: a `Text` with no colour of its own | `Text("…").ripulText()`, on the same line: the theme's text colour once a theme names one, and until then the text exactly as it was |
| with `--lists`: a `List` or a `Form`, and each `Section` | `.ripulThemedList()` after it, and `.ripulThemedListRows()` after each section |
| `Color("BrandNavy")`, where you declared a role for that asset | `Color.ripul(.navy)` |

`--text` and `--lists` write into your source what the plug-in does with no
edit, by the same reading of the source: the texts are the ones described
under "Which texts count as having no colour". Run them together:

```bash
$RIPUL_THEME migrate --named --text --lists <your source folder>
```

Then see what is left, and check the change:

```bash
$RIPUL_THEME check <your source folder>     # every font and colour still written directly; exit 1 while any is left
$RIPUL_THEME lint                           # the working tree's diff: did each replacement keep its value?
```

`lint` knows the lines `migrate` writes. A line you added by hand in the same
diff (the root line, a list modifier) it reports as "the hunk adds and removes
different numbers of lines": that is the lint not knowing the line, not a
moved value.

### What it leaves for you

These need a person, because each is a decision or something the SDK does not
yet do for you.

1. **Text with no colour of its own** is done by `--text`, and kept done by
   `check --text` in your build, which counts a text without the line. The
   line, `.ripulText()`, goes on the text itself. On the root, or on a
   container, a text colour changes what `.secondary` draws and recolours the
   labels of bordered and prominent buttons, links in a list and section
   headers (measured three times, the last on iOS 27.1 with both the
   one-colour and the three-colour form). `.ripulText()` leaves its text
   untouched until a theme names `text`, so with no theme, and under a theme
   that sets no text colour, a text the command misjudged still takes its
   colour from wherever it took it before. What is left for you is to look
   at the screens under a theme that does name `text`: a text that was
   coloured from another file, through a property or a modifier, now takes
   the theme's ink. Take the line off that one.
2. **Lists** are done by `--lists`. A row that is not inside a `Section`
   needs `.ripulThemedListRows()` written on it, or on the `ForEach` that
   makes the rows: the list's own modifier cannot reach its rows from
   outside (measured). Each modifier leaves its list untouched until a theme
   names a surface or a separator. A list, form or section that already
   sets `scrollContentBackground` or `listRowBackground` is left alone by the
   command: it has a ground of its own.
3. **Section headers and empty states.** `Section("Title")` becomes
   `Section(themed: "Title")`, a custom header `RipulSectionHeader { … }`, and
   `ContentUnavailableView("T", systemImage: "i")` becomes
   `ContentUnavailableView(themed: "T", systemImage: "i")`. Without these a
   header loses its weight under a themed family. Not inside a menu, a picker
   or a toolbar. A header takes the family, and the theme's `textSecondary`
   once a theme names it.
4. **A white or a blue that meant something.** `--named` writes the system
   form for white. Where the white sits on an accent fill, write
   `.ripul(.onAccent)`. Where a blue was the app's own colour and not a
   notice, write `.ripul(accentOr: .info)`: the accent once a theme names one.
5. **A colour of your own that is not one of the fifteen roles.** Declare it
   as a role of your own ("Your own colours", in step 2) and run `migrate`
   again: it rewrites each `Color("BrandNavy")` to the role you declared.
6. **Fonts the command could not place:** a fixed size on a view that is
   neither a `Text` nor an `Image`, a font held in a property
   (`var titleFont: Font { .caption }` becomes `.ripul(.caption)`), `.rounded`
   and `.serif` designs, a font helper of your own (`static func serif(…) ->
   Font`), and with `--named` a `.black.opacity(…)` inside a gradient or a
   shadow. `check` lists them.
7. **Colours that are data** (a category's colour, a chart's, a brand mark):
   mark the line `// theme-exempt: <reason>` and leave it.

Never keep a token in a `static let`, a model or a cache: it would not follow
a change. Read the accessor where the value is used.

### Keeping it themed

Run `check` in your build, so a new direct font or colour fails it. As a Run
Script phase:

```bash
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme" check "$SRCROOT/<your source folder>"
```

An app part way through adds `--baseline "$SRCROOT/theme-baseline.json"`: the
first run writes today's counts there, later runs fail only when a count
rises, and `--baseline <file> --update` lowers it. A zero from `check` is not
proof: it reads lines, not types, and cannot see a bare `.orange` passed to an
unlabelled parameter.

## 5. Light and dark

Both come from the document: every palette entry that should differ is a
pair. A role left at its default follows the system in both. Look at every
screen in both; the pair for `onAccent` is the one most often wrong (white on
a pale dark-mode accent cannot be read).

## 6. Switching while the app runs

```swift
RipulTheme.select("brand-large")              // another document in the bundle; kept for later launches
RipulTheme.select(RipulTheme.systemThemeName) // the system look, kept as a choice
RipulTheme.select(nil)                        // forget the choice: back to the theme the root names
RipulTheme.selectedTheme                      // what is in use; read in a body, it follows a change
RipulTheme.bundledThemes                      // every theme document in the bundle, with its own name

RipulThemePicker("Look")                      // a picker over all of the above, in one line
```

Everything on screen repaints, with nothing written in your views.
`select` returns false and changes nothing when the document is missing or
refused.

Two more ways in, for a developer and for tests, with no code:

- **A launch argument:** `-ripul.theme.document <name>`, with `system` for the
  system look. It is the `UserDefaults` key the choice is kept under, and as
  an argument it lasts for that one launch: nothing is stored.
- **A link, in a Debug build only:** `<your app's scheme>://theme?name=<name>`,
  with `name=system` for the system look. The root handles it. A store build
  ignores it; pass a URL to `RipulTheme.handleThemeLink(_:)` yourself if you
  want it there.

A build that must show one theme whatever was chosen before installs with
`RipulTheme.install(theme: "brand", keepsChoice: false)`.

What does not repaint by itself: UIKit code that read a colour or a font once
(read it again on `Notification.Name.ripulThemeDidChange`), and anything
computed outside a view's body and kept.

## 7. The View Explorer names your tokens

In a Debug build, selecting an element in the Ripul View Explorer lists the
theme tokens that style it, each with its value and whether it comes from the
document. The explorer reads that from a map written at build time. Add one
Run Script build phase holding one line:

```bash
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme" usage-map
```

In an XcodeGen `project.yml`:

```yaml
    postCompileScripts:
      - name: Theme usage map
        basedOnDependencyAnalysis: false
        script: '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme" usage-map'
```

It reads Xcode's own settings. It does nothing outside a Debug build, reads
the Swift files under the project's folder and the SDK's own screens, and
writes `ripul-theme-usage.json` into the app. It never fails a build. The
target needs `ENABLE_USER_SCRIPT_SANDBOXING = NO`, as any script that reads
the source does.

An element is known by its identifier: `.uiKitIdentifier("screen.element")` or
`.accessibilityIdentifier(…)`. **Your own identifier modifier is followed.** If
the app names controls through a wrapper,

```swift
func identified(_ name: String) -> some View { uiKitIdentifier(name) }
```

then `.identified("stay.cottage")` is read like the two it wraps. Nothing
declares it; the build log says which wrappers it followed.

To ask it directly: `$RIPUL_THEME usage-map --roots <folder> --no-sdk --stats`,
and `--explain <identifier>` for one element.

## 8. Check that nothing moved

Before the first edit (so before step 1, though it is written here), take
screenshots of your screens in light and dark, and take the whole set twice:
on iOS 26 and later a glass control differs between two captures of one build,
and the second set shows you which screens do that. After the migration, with
no document or an empty one, or launched with `-ripul.theme.document system`,
take them again and compare them pixel for pixel. Apart from those screens
they should be the same. Where they are not, a
replacement was a judgement and not an identity: `lint` names most of those,
and the lists and text colours of step 4 are the usual rest.

## What the system draws that a theme does not reach

- **Reached, with no edit:** the accent on toolbar buttons, toggles, buttons,
  menus, progress bars, sliders, the selected tab and alert buttons; the text
  family on form rows, buttons, navigation titles (large and inline),
  segmented controls and tab bar labels.
- **Reached from 0.7.175, with no edit:** the colour of a navigation title,
  large and inline, under a theme that names `text`.
- **Not reached:** alerts' text, menus, swipe action labels, a menu picker's
  value; a navigation title on Mac Catalyst.
- **Under a themed accent, things that had no colour take it:** toolbar
  buttons, a swipe action with no tint, a toggle's on colour.
- A document cannot ask for a font feature (lining figures, for one).
- On Mac Catalyst give every sized role a `catalystSize`, and a presented view
  needs a root inside it. See "Measured again, with Mac Catalyst" in
  [theming.md](theming.md).

## Not built

- **Editing a theme in the app.** A look is tried by loading a document.
- **A font feature in the document** (lining figures, for one).
- The widgets and other extensions of an app are not themed unless they link
  the package and install the theme themselves.

## What was tried and is not used

So that nobody tries them again without a reason:

- **A text colour on the root or a container.** Recolours controls and
  changes `.secondary`; see step 4.
- **Replacing UIKit's colour getters** (`UIColor.label`,
  `systemGroupedBackground`, `separator`) while a theme is in use. Measured
  on iOS 27.1: a SwiftUI `Text` outside a list does not read `UIColor.label`,
  so text is not reached; a list's ground and separators are, but its rows
  are not (they use a colour with no public getter), a change of theme while
  the app runs leaves grounds and separators on the old colours, and an
  alert's message darkens. Not used.
- **UIKit's appearance settings and the root's own modifiers for a list.**
  `UICollectionView.appearance()` does not reach a SwiftUI list;
  `.scrollContentBackground(.hidden)`, `.listRowBackground` and
  `.listRowSeparatorTint` set on the root reach nothing below it.
- **Setting each visible cell's background from outside.** Works until a cell
  is reused or pressed. Not used.

## The API in one place

```swift
.ripulThemeRoot(theme: "brand")          // the root of your own tree
.ripulThemeRoot()                        // any other root; reads Info.plist's RipulTheme
.ripulThemeRoot(window: true)            // a window's own root: it draws the theme's canvas behind the tree
RipulTheme.install(theme:bundle:keepsChoice:)
RipulTheme.select(_:)   RipulTheme.selectedTheme   RipulTheme.bundledThemes
RipulTheme.handleThemeLink(_:)           RipulThemePicker(_:systemTitle:)
RipulTheme.adopt(documentData:)          // a document from anywhere else, such as your server
RipulTheme.resetToDefaults()
RipulTheme.color(.accent)   RipulTheme.isDefault(.accent)
RipulColorRole(asset: "BrandNavy")   RipulColorRole("cream", default: "#F4EBDD", dark: "#2A2418")   // roles of your own

Font.ripul(.body)   Font.ripul(.title, weight: .bold, family: .display)   Font.ripul(size: 14)
Font.ripulIcon(.title2)   Font.ripulIcon(size: 18)
.ripul(.textSecondary)            // as a style: foregroundStyle, fill, background, tint
Color.ripul(.danger)              // where a Color is required
.ripul(system: .systemGray5)      // a system colour, never themed
.ripul(accentOr: .info)
UIColor.ripul(.canvas)   UIFont.ripul(.caption)
.ripulTextStyle(.eyebrow)   .ripulProminentButtonStyle()   .ripulGlassProminentButtonStyle()   Section(themed:)   ContentUnavailableView(themed:)
.ripulText()   .ripulThemedList()   .ripulThemedListRows()   .ripulSectionHeader()   .ripulSectionFooter()
```
