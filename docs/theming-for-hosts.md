# A theme for your app

This page is for an app that links the RipulAgent package and wants its own
fonts and colours to come from a theme: one JSON document, light and dark,
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
Swift changes. It is in the package from release 0.7.172, and it has been
measured on one app. It is where to start: the numbered steps are for an app
that wants what this does not reach.

What you do:

1. Add the package to the app target, as in step 1 below, without the root
   line.
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
`Font.system(size:)`, `Color.red`, `Color(.systemBackground)`,
`.foregroundStyle(.secondary)`, `WindowGroup`. Inside your module your
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
| `WindowGroup { … }` | the theme root, with no line written: the accent, the body font for text with none, navigation titles, tab bar labels |
| identified elements | the View Explorer names their tokens (Debug builds), with no build phase |

**What it does not reach.** These stay the system's under a theme, where the
migration command or a line of yours would have reached them:

- text with no colour of its own, as in "What it leaves for you", 1;
- lists, section headers and empty states, as in 2 and 3;
- a prominent button's label (`onAccent`);
- a hierarchy style given to `fill`, `stroke` or `background`, and one passed
  through a variable of a generic type;
- a colour of your own (`Color("BrandNavy")`), and white and black;
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
  `foregroundStyle` alone.
- A font or colour kept in a `static let` is read once and does not follow a
  switch while the app runs.
- The rule this rests on, that a module's own declaration is preferred to an
  imported one of the same name and type, is how the Swift compiler behaves
  (measured with Swift 6.4, Xcode 27.1, in Swift 5 and Swift 6 language
  modes). The language's documentation does not promise it.

The two ways mix: a file you have migrated calls the accessors directly, and
the rest goes through the generated file.

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

  The set is closed: a document cannot add a role (see the end).
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
nothing moves on screen. It adds no import: each file it rewrote needs
`import RipulAgent`, or the app one `@_exported import RipulAgent`. It rewrites:

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

1. **Text with no colour of its own.** A `Text` that never had a colour is
   drawn in the system's label colour, not the theme's `text`. Give it
   `.foregroundStyle(.ripul(.text))`. It must go on the text itself. On the
   root, or on a container, it changes what `.secondary` draws and recolours
   the labels of bordered and prominent buttons, links in a list and section
   headers, even under the default document (measured). Until the SDK finds
   a way, this is one line a text, and a new `Text` without it stays the
   system's colour silently.
2. **Lists.** A grouped list's ground, rows and separators stay the system's
   under a theme. Set them where you want them themed:
   `.scrollContentBackground(.hidden)` and `.background(.ripul(.surfaceSunken))`
   on the list, `.listRowBackground(Color.ripul(.surface))` on a section or a
   row (on the list itself it does nothing), `.listRowSeparatorTint(Color.ripul(.separator))`.
   Compare a screenshot under the default document afterwards: these have not
   been measured as identical by the SDK.
3. **Section headers and empty states.** `Section("Title")` becomes
   `Section(themed: "Title")`, a custom header `RipulSectionHeader { … }`, and
   `ContentUnavailableView("T", systemImage: "i")` becomes
   `ContentUnavailableView(themed: "T", systemImage: "i")`. Without these a
   header loses its weight under a themed family. Not inside a menu, a picker
   or a toolbar. A header takes the family and keeps the system's colour.
4. **A white or a blue that meant something.** `--named` writes the system
   form for white. Where the white sits on an accent fill, write
   `.ripul(.onAccent)`. Where a blue was the app's own colour and not a
   notice, write `.ripul(accentOr: .info)`: the accent once a theme names one.
5. **A colour of your own that is not one of the fifteen roles.** There is no
   place for it in the document yet. Keep it in your code, and if it should
   give way to the theme, read `RipulTheme.isDefault(.accent)` where it is
   used: `RipulTheme.isDefault(.accent) ? myNavy : Color.ripul(.accent)`.
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
- **Not reached:** the colour of a large navigation title and of a section
  header (the family is); alerts' text, menus, swipe action labels, a menu
  picker's value; a navigation title on Mac Catalyst.
- **Under a themed accent, things that had no colour take it:** toolbar
  buttons, a swipe action with no tint, a toggle's on colour.
- A document cannot ask for a font feature (lining figures, for one).
- On Mac Catalyst give every sized role a `catalystSize`, and a presented view
  needs a root inside it. See "Measured again, with Mac Catalyst" in
  [theming.md](theming.md).

## Not built

Each of these is a decision the SDK has not taken yet. Until it is, the cost
is yours, as described above.

- **A theme layer on its own.** The theme is part of `RipulAgent`: an app that
  wants only the theme links the whole package, in Release too.
- **Your own roles in the document.** The fifteen are all there are.
- **Text colour without a line a text.**
- **Lists themed from the root.**
- **Editing a theme in the app.** A look is tried by loading a document.
- The widgets and other extensions of an app are not themed unless they link
  the package and install the theme themselves.

## The API in one place

```swift
.ripulThemeRoot(theme: "brand")          // the root of your own tree
.ripulThemeRoot()                        // any other root; reads Info.plist's RipulTheme
RipulTheme.install(theme:bundle:keepsChoice:)
RipulTheme.select(_:)   RipulTheme.selectedTheme   RipulTheme.bundledThemes
RipulTheme.handleThemeLink(_:)           RipulThemePicker(_:systemTitle:)
RipulTheme.adopt(documentData:)          // a document from anywhere else, such as your server
RipulTheme.resetToDefaults()
RipulTheme.color(.accent)   RipulTheme.isDefault(.accent)

Font.ripul(.body)   Font.ripul(.title, weight: .bold, family: .display)   Font.ripul(size: 14)
Font.ripulIcon(.title2)   Font.ripulIcon(size: 18)
.ripul(.textSecondary)            // as a style: foregroundStyle, fill, background, tint
Color.ripul(.danger)              // where a Color is required
.ripul(system: .systemGray5)      // a system colour, never themed
.ripul(accentOr: .info)
UIColor.ripul(.canvas)   UIFont.ripul(.caption)
.ripulTextStyle(.eyebrow)   .ripulProminentButtonStyle()   .ripulGlassProminentButtonStyle()   Section(themed:)   ContentUnavailableView(themed:)
```
