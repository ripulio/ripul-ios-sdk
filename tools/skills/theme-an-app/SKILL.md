---
name: theme-an-app
description: Give a SwiftUI iPhone or iPad app its own fonts and colours, light and dark, from one theme document, using the RipulAgent Swift package. Use when asked to theme, brand or restyle an app, to make an app follow a website's or a brand's look, to adapt an app's source to theme tokens, or to say what a theme would reach in an app.
---

# Giving an app a theme

A theme here is one JSON document: colours for light and dark, three font families, and sizes and weights. The RipulAgent Swift package reads it and the app's own screens follow it. This is the procedure for doing that in someone's repository. Follow it in order. It needs RipulAgent 0.7.172 or later.

Three rules hold throughout:

- **With no theme document the app must look exactly as it did.** Every step below keeps that, and you prove it with screenshots before you call the work done.
- **Start with the level that changes no source.** Go further only where the person asks for more.
- **The tools read text, not Swift.** What they write and what they count is a draft. A build and a screenshot are the proof.

## 1. Find out what the app is

Read the repository's instructions for agents and its project files before anything else. You need to know:

- **Is it a SwiftUI app for iOS?** This works for a SwiftUI app with a deployment target of iOS 17 or later. If the repository is something else (a website, an Android app, a server, a React Native or Flutter app), say so plainly and stop: nothing here applies. A UIKit app can read the theme through `UIColor.ripul(…)` and `UIFont.ripul(…)` by hand, and gets nothing from levels 1 and 3; say that and ask before going on.
- **How it is built**: an XcodeGen `project.yml`, a hand-kept `.xcodeproj`, or a Swift package; the scheme; where build output goes; which Xcode.
- **Does it link the package already**, and at which version? Look for `ripul-ios-sdk` in `project.yml`, `Package.swift` or `Package.resolved`.
- **How a screen is opened without tapping**: launch arguments, deep links, previews. You will need this for screenshots.

If the person asked only what a theme would reach, do step 3 and stop: change nothing and report.

## 2. Work on a branch

Never on the default branch. Make a branch from it (`git switch -c theme`). If the working tree has changes you did not make, say so and ask before going on. Commit as you go, so each level can be kept or dropped by itself.

## 3. Measure before you touch anything

**Get the tools.** They are in the package, in `tools/`, and need only `python3`. Where the app links the package they are in its checkout: `<derived data>/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme` in an Xcode project, `.build/checkouts/ripul-ios-sdk/tools/ripul-theme` in a Swift package. Where it does not yet, or to look without building: `git clone --depth 1 https://github.com/ripulio/ripul-ios-sdk /tmp/ripul-ios-sdk`.

**Count what a theme would reach.** Neither command changes a file:

```bash
ripul-theme check <source folder>                      # every font and colour written at a call site, by kind
ripul-theme migrate --dry-run --named <source folder>  # the lines level 3 would rewrite
```

Then count by search what no level reaches without a decision: `Text(` with no colour of its own, `List` and `Form`, the app's own colours (`Color("…")`, an asset catalogue, a `Brand` type), and UIKit code. Report these beside the tool's counts.

**Take the baseline screenshots.** Build the untouched app and capture every screen you can open, in light and in dark (`xcrun simctl ui <simulator> appearance dark`). Fix the clock first (`xcrun simctl status_bar <simulator> override --time 9:41`). Wait for each screen to finish drawing before capturing it. **Capture the whole set twice.** On iOS 26 and later a glass control differs by a thousand or so pixels between two captures of one build, and an animated screen always differs; the second set tells you which screens do that, so that later you do not chase them.

## 4. Level 1: a theme with no change to the source

The package has a build-tool plug-in, `RipulThemeRedirect`. On each build it writes one Swift file into the build folder, and that file is compiled into the app. It declares SwiftUI's own names again (`Font.body`, `Color(.systemBackground)`, `.foregroundStyle(.secondary)`, `WindowGroup`), each as one call into the package, so the app's existing code follows the theme. No Swift file of the app changes.

1. **Add or move the package** to 0.7.172 or later: `https://github.com/ripulio/ripul-ios-sdk`, product `RipulAgent`, on the app target.
2. **Switch the plug-in on for the app target.** In an XcodeGen `project.yml`, under the target:

   ```yaml
       buildToolPlugins:
         - plugin: RipulThemeRedirect
           package: RipulAgent      # the name the package has under `packages:`
   ```

   In a hand-kept Xcode project it is the target's Build Phases, "Run Build Tool Plug-ins": ask the person to add it there, since a project file edited by hand is easy to break. In a Swift package it is `plugins: [.plugin(name: "RipulThemeRedirect", package: "ripul-ios-sdk")]` on the target (this compiles; it has not been run in a real package host).
3. **Allow the plug-in to run.** Xcode refuses a package's plug-in until it is trusted, and the build fails with the one line `Validate plug-in “RipulThemeRedirect” in package “ripul-ios-sdk”`. On the command line add `-skipPackagePluginValidation` to every `xcodebuild` call, and add it to the repository's build scripts and written commands too, or the next agent meets the same failure. In Xcode itself the person is asked once, "Trust & Enable".
4. **Build with no theme document yet**, and take the screenshots again. Compare them with the baseline pixel for pixel, by decoding both and counting the pixels that differ, never by eye. They must match, apart from the screens your two baseline sets showed to differ by themselves. If the build fails with "invalid redeclaration" or "ambiguous use", the app declares a name the generated file also declares; the header of the generated file names two flags that leave a part out (`RIPUL_THEME_NO_ROOT`, `RIPUL_THEME_NO_STYLES`). `docs/theming-for-hosts.md` in the package checkout, "What can go wrong", has the rest.

## 5. Write the theme document

Ask what the look should follow if the person has not said: a website, a brand file, a design. Then take the values from it; do not invent a palette.

- **From a website:** fetch its stylesheets and read the page background, the text colour, the accent (links and buttons), the card and panel colours, and the font families for headings and for text. Report the values you took and where each came from.
- **Write `<name>.json`** in a folder the app bundles (the bundle's top level, or a folder named `Theme` or `Themes`). The keys, the fifteen colour roles and what each is for are in `docs/theming-for-hosts.md`, "Write the document". Start from `{ "schema": 1, "name": "…" }`, which changes nothing, and add to it.
- **Light and dark are both yours to write.** A source that has only a light look gives you no dark values: derive them, say that you derived them, and check each dark text colour against its background yourself. Nothing checks contrast. The pair most often wrong is `onAccent` on a pale dark-mode accent.
- **With one theme document in the bundle, it is the app's theme** at the next launch. With more than one, name one with the Info.plist key `RipulTheme`, or the app stays on the system look and says so in its log.

**Fonts.** A font may be bundled only if its licence allows embedding in an app. Fonts served by Adobe Fonts, and most fonts a foundry sells for the web, do not allow it. When the brand's font cannot be bundled, say so, propose the nearest font that can (the SIL Open Font Licence allows it), and let the person decide. Put the `.ttf` or `.otf` files in the bundle (top level, or a folder named `Fonts`), each font's licence file beside it, and a short note of where each file came from. Write no registration code and no Info.plist entry: the package registers the files a document names. The name in the document is the font's family name ("Source Sans 3"), not its file name. Prefer a variable font: a file with one weight draws that weight whatever is asked.

**Look at it.** Build, and capture the same screens in light and dark. Open the pictures and read them. To see the app without the theme, launch it with `-ripul.theme.document system`; to see another document, pass its name. That argument lasts for one launch.

## 6. Say what level 1 did not reach, and ask

Level 1 reaches: text styles and fixed sizes, a serif or monospaced design, hierarchy styles in `foregroundStyle`, the system background colours, the named state colours (red, orange, green, blue, grey), the accent, navigation titles and tab labels.

It does not reach, and you should name each with the screens where it shows:

- **text with no colour of its own**, which stays the system's black or white on the theme's ground;
- **lists and forms**: their ground, rows and header colour;
- **the app's own colours** (an asset colour, a `Brand` type), and white and black;
- a prominent button's label, a hierarchy style given to `fill`, `stroke` or `background`, and UIKit code.

**Stop here and ask.** Show the themed screenshots, list what was not reached, and ask which the person wants: stop at level 1; fix the few places that matter (level 2); or adapt the whole source (level 3). Do not go on unasked.

## 7. Level 2: a few lines where it matters

Each is a small edit in the app's source, in a file that imports `RipulAgent`. The forms are in `docs/theming-for-hosts.md`, "What it leaves for you". The three that matter most:

- **A text colour:** `.foregroundStyle(.ripul(.text))` on the `Text` itself. Never on a container or the root: there it recolours the labels of buttons, list links and section headers.
- **A list:** `.scrollContentBackground(.hidden)` and `.background(.ripul(.surfaceSunken))` on the list, and `.listRowBackground(Color.ripul(.surface))` on each section or row. On the list itself the row background does nothing.
- **The app's own colour:** ask. Either it stays fixed, or it gives way to the theme: `RipulTheme.isDefault(.accent) ? myNavy : Color.ripul(.accent)`, read where it is used. A theme document cannot name a colour outside the fifteen roles.

## 8. Level 3: adapt the source

Only when asked. It rewrites call sites to explicit accessors (`.font(.ripul(.body))`), so the source says it is themed and a check can keep it so. The two levels mix a file at a time: a migrated file calls the accessors, and the rest still goes through the plug-in.

```bash
ripul-theme migrate --dry-run --named <source folder>   # read this first
ripul-theme migrate --named <source folder>
ripul-theme check <source folder>                       # what is left; exit 1 while any is
ripul-theme lint                                        # did each replacement keep its value?
```

What the tool does not do, each measured on a real app:

- **It adds no `import RipulAgent`.** Every file it rewrote needs one, or one `@_exported import RipulAgent` in the app's main file.
- **It does not follow the app's own font helper** (`static func serif(…) -> Font`), and with `--named` it leaves `.black.opacity(…)` inside a gradient or a shadow. `check` lists each.
- **`lint` reports a line you added by hand** (a root line, a list modifier) as "the hunk adds and removes different numbers of lines". That is the lint not knowing the line, not a moved value.
- **A zero from `check` is not proof.** It cannot see a bare `.orange` passed to an unlabelled parameter, or a new `Text` with no colour.

Finish what `check` lists by the tables in `docs/theming-for-hosts.md` ("Move the call sites" and "What it leaves for you"). A colour that is data (a category's, a chart's, a shade over a photo) takes `// theme-exempt: <reason>` on its line and stays.

## 9. Prove nothing moved

After the last edit, whatever the level:

1. Launch with `-ripul.theme.document system` (or with no theme document in the bundle) and capture every baseline screen again, light and dark.
2. Compare with the baseline pixel for pixel. A screen that differs must be one that differed between your two baseline sets, in the same place. Anything else is an edit that changed the app: find it and fix it.
3. After level 3, `lint` must have nothing to say about a line the tool wrote.
4. Build Release once. The View Explorer's map is left out of it, and the theme must still load.

## 10. Hand back a ledger

Do not merge. Report, with each line marked measured or reasoned:

- the branch, and what `git diff --shortstat <default branch>` reads; how many Swift lines changed (none, after level 1);
- the files added: the document, each font with its licence and where it came from, any stand-in for a font that could not be bundled;
- every build command and script that gained `-skipPackagePluginValidation`;
- what follows the theme and what does not, by kind, with a screenshot for each;
- the comparison: how many screens, how many the same, and why each of the others differs;
- every decision you made for the person and every one still open (the app's own colours, dark values you derived, a font you substituted);
- what you did not test: a phone, Dynamic Type, Increased Contrast, right-to-left, an archive.

## Limits to say out loud

- Level 1 rests on how the Swift compiler chooses between two declarations of one name, measured with Swift 6.4 and Xcode 27.1 and not promised by the language. If a compiler changes it, the likely result is a compile error in the app's files, and the cure is to switch the plug-in off.
- The theme is part of the whole package: an app that wants only the theme links all of it, in Release too.
- A theme document cannot add a colour role, ask for a font feature such as lining figures, or colour a large navigation title or a section header.
- If you are running inside Ripul (you have a `ripul_guide` tool), read its `devices` and `trains` guides before you install a build on a phone or use a simulator another agent may hold.
