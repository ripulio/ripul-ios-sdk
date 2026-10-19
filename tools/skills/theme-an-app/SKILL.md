---
name: theme-an-app
description: Give a SwiftUI iPhone or iPad app its own fonts and colours, light and dark, from one theme document, using the RipulAgent Swift package. Use when asked to theme, brand or restyle an app, to make an app follow a website's or a brand's look, to adapt an app's source to theme tokens, or to say what a theme would reach in an app.
---

# Giving an app a theme

A theme here is one JSON document: colours for light and dark, three font families, and sizes and weights. The RipulAgent Swift package reads it and the app's own screens follow it. This is the procedure for doing that in someone's repository. Follow it in order. It needs RipulAgent 0.7.176 or later: 0.7.174 is the first whose level 1 reaches text, lists and the app's own colours and the first with the theme as a product of its own, and 0.7.175 adds markdown and every other kind of text, a label's title, a prominent button's label and a navigation title's colour. From 0.7.176 `migrate --text` writes `.ripulText()`, and a window's root draws the theme's canvas behind a screen with no ground of its own.

Four rules hold throughout:

- **With no theme document the app must look exactly as it did.** Every step below keeps that, and you prove it with screenshots before you call the work done.
- **Start with the level that changes no source.** Go further only where the person asks for more.
- **The tools read text, not Swift.** What they write and what they count is a draft. A build and a screenshot are the proof.
- **A question nobody answers is not a reason to stop.** The person may be away. Where a step says to ask, ask once; if no answer comes, take the choice that is easiest to undo, make it in a commit of its own, go on, and list it in the ledger as a decision still open. The one place to stop without an answer is the end of level 1 (step 6): by then the app is themed.

## 1. Find out what the app is

Read the repository's instructions for agents and its project files before anything else. You need to know:

- **Is it a SwiftUI app for iOS?** This works for a SwiftUI app with a deployment target of iOS 17 or later. If the repository is something else (a website, an Android app, a server, a React Native or Flutter app), say so plainly and stop: nothing here applies. A UIKit app can read the theme through `UIColor.ripul(…)` and `UIFont.ripul(…)` by hand, and gets nothing from levels 1 and 3; say that and ask before going on.
- **How it is built**: an XcodeGen `project.yml`, a hand-kept `.xcodeproj`, or a Swift package; the scheme; where build output goes; which Xcode.
- **Does it link the package already**, and at which version? Look for `ripul-ios-sdk` in `project.yml`, `Package.swift` or `Package.resolved`.
- **How a screen is opened without tapping**: launch arguments, deep links, previews. You will need this for screenshots.

If the person asked only what a theme would reach, do step 3 and stop: change nothing and report.

**Check that your session can do the work**, before you measure anything. It has to write inside `.git` (try `git switch -c theme`, step 2), fetch a package from github.com, and run `xcodebuild` and a simulator. A sandboxed session often can do none of these: Codex in its workspace sandbox cannot write `.git` or reach the network. If one fails, say at once which, and that the chat needs full access (in Ripul, the Codex settings have a Permission Mode, and "Full access" is the one that allows Xcode builds), and stop there. Do not hand back an audit as if it were the work.

## 2. Work on a branch

Never on the default branch. Make a branch from it (`git switch -c theme`). If the working tree has changes you did not make, say so and ask before going on. Record the starting commit with `git rev-parse HEAD` before any theme edit and keep it in the ledger as `<theme-base>`. Commit as you go, so each level can be kept or dropped by itself.

## 3. Measure before you touch anything

**Get the tools.** They are in the package, in `tools/`, and need only `python3`. Where the app links the package they are in its checkout: `<derived data>/SourcePackages/checkouts/ripul-ios-sdk/tools/ripul-theme` in an Xcode project, `.build/checkouts/ripul-ios-sdk/tools/ripul-theme` in a Swift package. Where it does not yet, or to look without building: `git clone --depth 1 https://github.com/ripulio/ripul-ios-sdk /tmp/ripul-ios-sdk`.

**Count what a theme would reach.** Neither command changes a file:

```bash
ripul-theme check <source folder>                      # every font and colour written at a call site, by kind
ripul-theme migrate --dry-run --named <source folder>  # the lines level 3 would rewrite
```

Add `--text` to `check` to list each `Text` with no colour of its own, as level 1 will read them. Then count by search what no level reaches without a decision: the app's own colours that are not written `Color("Name")` (a `Color(red:…)`, a generated `Color(.brandNavy)`), a `List` written `List($items)` or with `children:`, a `Section(isExpanded:)`, and UIKit code. Report these beside the tool's counts.

**Take the baseline screenshots.** Build the untouched app and capture every screen you can open, in light and in dark (`xcrun simctl ui <simulator> appearance dark`). Fix the clock first (`xcrun simctl status_bar <simulator> override --time 9:41`). Wait for each screen to finish drawing before capturing it. **Capture the whole set twice, and compare the two sets with each other first.** Two captures of one untouched build are not the same picture: on iOS 26 and later the glass tab bar, a glass toolbar button, the home indicator and the Dynamic Island differ from one capture to the next, and an animated screen always does. On one app a third of the screens differed between two captures of the same build. So record, for each screen, where the two sets differ (the box that holds the differing pixels), not only whether they do. Later, a difference inside one of those boxes is the system's, and a difference anywhere in the app's own content is yours.

A Mac has no image library for this by itself: make a Python virtual environment under `/tmp` with Pillow, and write a short script that counts differing pixels and prints their bounding box.

## 4. Level 1: a theme with no change to the source

The package has a build-tool plug-in, `RipulThemeRedirect`. On each build it writes one Swift file into the build folder, and that file is compiled into the app. It declares SwiftUI's own names again (`Font.body`, `Color(.systemBackground)`, `Color("Name")`, `.foregroundStyle(.secondary)`, `Text`, `List`, `Form`, `Section`, `WindowGroup`), each as one call into the package, so the app's existing code follows the theme. No Swift file of the app changes.

1. **Add or move the package** to 0.7.176 or later, `https://github.com/ripulio/ripul-ios-sdk`, on the app target. **Which product:** an app that does not link the package yet, and was asked only for a theme, links `RipulThemeKit`, the theme alone (about 2 MB of a shipping app). Do not give it `RipulAgent`, the whole SDK with its developer console (about 60 MB), unless the person asks for the console. An app that links `RipulAgent` already keeps it; if everything of the app's that uses it is inside `#if DEBUG`, say that the SDK can be left out of the shipping app with one build setting, and where: `docs/theming-for-hosts.md`, "Shipping only the theme".
2. **Switch the plug-in on for the app target.** In an XcodeGen `project.yml`, under the target:

   ```yaml
       buildToolPlugins:
         - plugin: RipulThemeRedirect
           package: RipulAgent      # the name the package has under `packages:`
   ```

   In a hand-kept Xcode project (a `.xcodeproj` in git, no generator), make both changes of steps 1 and 2 in `project.pbxproj` yourself, in a commit of their own. Do not ask a person to click: it is six objects, and a build proves them. Where the `xcodeproj` Ruby gem is installed (`gem list xcodeproj`), write them with it; otherwise edit the text, giving each new object a 24-character hexadecimal id that the file does not use. The project gains:

   - one `XCRemoteSwiftPackageReference`, with `repositoryURL = "https://github.com/ripulio/ripul-ios-sdk";` and `requirement = { kind = upToNextMinorVersion; minimumVersion = 0.7.176; };`, listed in the project object's `packageReferences`;
   - two `XCSwiftPackageProductDependency` objects, each with `package =` that reference: one with `productName = RipulThemeKit;` (or `RipulAgent`, by step 1), one with `productName = "plugin:RipulThemeRedirect";`;
   - the first of them in the app target's `packageProductDependencies`, and in a `PBXBuildFile` (`productRef =` it) listed in the target's Frameworks build phase. A target with no `PBXFrameworksBuildPhase` needs one made and added to its `buildPhases`;
   - one `PBXTargetDependency` with `productRef =` the plug-in's object, listed in the target's `dependencies`. This is what Xcode shows as Build Phases, "Run Build Tool Plug-ins".

   Then `xcodebuild -list -project <project>` must still read the project, and the build of step 4 must pass. Commit the `Package.resolved` the build writes inside the project, if the repository keeps one or has none to compare with.

   In a Swift package it is `plugins: [.plugin(name: "RipulThemeRedirect", package: "ripul-ios-sdk")]` on the target (this compiles; it has not been run in a real package host).
3. **Allow the plug-in to run.** Xcode refuses a package's plug-in until it is trusted, and the build fails with the one line `Validate plug-in “RipulThemeRedirect” in package “ripul-ios-sdk”`. On the command line add `-skipPackagePluginValidation` to every `xcodebuild` call, and add it to the repository's build scripts and written commands too, or the next agent meets the same failure. In Xcode itself the person is asked once, "Trust & Enable".
4. **Build with no theme document yet**, and take the screenshots again. Compare them with both baseline sets pixel for pixel, by decoding the pictures and counting the pixels that differ, never by eye. They must match, apart from the places your two baseline sets showed to differ by themselves. Capture a screen again before you believe a new difference in the status bar or the tab bar. If the build fails with "invalid redeclaration" or "ambiguous use", the app declares a name the generated file also declares; the header of the generated file names the flags that leave a part out (`RIPUL_THEME_NO_ROOT`, `RIPUL_THEME_NO_STYLES`, `RIPUL_THEME_NO_TEXT`, `RIPUL_THEME_NO_LISTS`, `RIPUL_THEME_NO_BUTTONS`). Read the build log for lines that begin `ripul-theme redirect:`: each names something the generated file left to SwiftUI, such as a `List` written in a form it does not have. `docs/theming-for-hosts.md` in the package checkout, "What can go wrong", has the rest.

## 5. Write the theme document

Ask what the look should follow if the person has not said: a website, a brand file, a design. Then take the values from it; do not invent a palette.

- **From a website:** fetch its stylesheets and read the page background, the text colour, the accent (links and buttons), the card and panel colours, and the font families for headings and for text. Report the values you took and where each came from.
- **Write `<name>.json`** in a folder the app bundles (the bundle's top level, or a folder named `Theme` or `Themes`). The keys, the fifteen colour roles and what each is for are in `docs/theming-for-hosts.md`, "Write the document". Start from `{ "schema": 1, "name": "…" }`, which changes nothing, and add to it.
- **Light and dark are both yours to write.** A source that has only a light look gives you no dark values: derive them, say that you derived them, and check each dark text colour against its background yourself. Nothing checks contrast. The pair most often wrong is `onAccent` on a pale dark-mode accent.
- **Check the app's own colours against your grounds, in both modes, and name them in the document where they need to change.** A colour the app reads as `Color("BrandNavy")` from its asset catalogue is a role named `BrandNavy`: under `roles`, `"BrandNavy": { "light": "#24386b", "dark": "#5b78c4" }` changes it, and until a document names it it is the asset. A button filled with the app's own navy disappears on a dark ground of the same navy: give that role a dark value that can be seen. Level 1 must be fit to use in both modes when you hand it back: no control, badge or text of the app may be lost on your ground in either. A colour kept in a `static let` takes the theme at launch and does not follow a switch while the app runs; say so. A colour written any other way (`Color(red:…)`, a generated `Color(.brandNavy)`) is not reached without an edit: choose a ground it can be seen on, or tell the person that level 2 is needed for it.
- **Make sure the file reaches the bundle.** A project that lists its files one by one (most hand-kept ones) does not bundle a file because it is in the folder: add the document, and later each font file, to the app target's resources in the project file. Then look inside the built `.app` for them. A theme that does nothing is most often a document that was never copied.
- **With one theme document in the bundle, it is the app's theme** at the next launch. With more than one, name one with the Info.plist key `RipulTheme`, or the app stays on the system look and says so in its log.

**Fonts.** A font may be bundled only if its licence allows embedding in an app. Fonts served by Adobe Fonts, and most fonts a foundry sells for the web, do not allow it. When the brand's font cannot be bundled, say so, propose the nearest font that can (the SIL Open Font Licence allows it), and ask the person once. If no answer comes, do not leave the app on the system's fonts: bundle the font you proposed in a commit of its own, so that it can be dropped, and list it in the ledger as a decision still open. Put the `.ttf` or `.otf` files in the bundle (top level, or a folder named `Fonts`), each font's licence file beside it, and a short note of where each file came from. Write no registration code and no Info.plist entry: the package registers the files a document names. The name in the document is the font's family name ("Source Sans 3"), not its file name. Prefer a variable font: a file with one weight draws that weight whatever is asked.

**Look at it.** Build, and capture the same screens in light and dark. Open the pictures and read them. To see the app without the theme, launch it with `-ripul.theme.document system`; to see another document, pass its name. That argument lasts for one launch.

## 6. Say what level 1 did not reach, and ask

Level 1 reaches: text styles and fixed sizes, a serif or monospaced design, hierarchy styles in `foregroundStyle`, text with no colour of its own however it is made (a string, markdown, a date, a number), a label's title, lists, forms and their sections, the label of a prominent button the app does not tint itself, a navigation title's colour, the system background colours, the named state colours (red, orange, green, blue, grey), the app's own asset colours that the document names, the accent, navigation titles and tab labels.

It does not reach, and you should name each with the screens where it shows:

- **text the build leaves alone**: a text inside a view of the app's own that is coloured where it is used (a row dimmed from outside), a text made with `+`, and a `TextField`'s text. These stay the system's black or white on the theme's ground;
- **text that took a container's or a control's colour before and now takes the theme's**, where the build could not see that from the source. Look at every themed screen for text that turned the theme's ink on a photo, a filled button or a coloured panel. `ripul-theme check --text <source folder>` lists the lines it themes;
- **a list, form or section the build log named** as left to SwiftUI;
- **the app's own colours not written `Color("Name")`**, and white and black;
- **a prominent button the app tints itself** (`.tint(Brand.navy)`): its label stays the system's white, so give that colour's role a dark value white can be read on;
- a hierarchy style given to `fill`, `stroke` or `background`, and UIKit code.

**Stop here and ask.** Show the themed screenshots, list what was not reached, and ask which the person wants: stop at level 1; fix the few places that matter (level 2); or adapt the whole source (level 3). Do not go on unasked.

## 7. Level 2: a few lines where it matters

Each is a small edit in the app's source, in a file that imports `RipulThemeKit` (or `RipulAgent`, which contains it). The forms are in `docs/theming-for-hosts.md`, "What it leaves for you" and "Your own colours". The ones that matter most:

- **A text level 1 missed:** `.ripulText()` on the `Text` itself. Never on a container or the root: there it recolours the labels of buttons, list links and section headers.
- **A text level 1 themed that should have kept a container's colour:** give the text that colour itself, or put it on a line with a coloured text.
- **A list level 1 left to SwiftUI:** `.ripulThemedList()` on the list, and `.ripulThemedListRows()` on each section or row. On the list itself a row background does nothing.
- **The app's own colour that is not an asset colour:** declare it as a role with today's value as the default, `static let navy = RipulColorRole("navy", default: "#24386b")` in an `extension RipulColorRole`, read it as `.ripul(.navy)`, and name `navy` under `roles` in the document.

## 8. Level 3: adapt the source

Only when asked. It rewrites call sites to explicit accessors (`.font(.ripul(.body))`), so the source says it is themed and a check can keep it so. The two levels mix a file at a time: a migrated file calls the accessors, and the rest still goes through the plug-in.

```bash
ripul-theme migrate --dry-run --named --text --lists <source folder>   # read this first
ripul-theme migrate --named --text --lists <source folder>
ripul-theme check --text <source folder>                # what is left; exit 1 while any is
ripul-theme lint <theme-base>                           # compare with the recorded starting commit
```

`lint` without a revision compares with `HEAD`: after you commit, it can check zero changes. Always pass the recorded starting commit, including for the final check. A clean working tree is not evidence that the migration preserved values.

What the tool does not do, each measured on a real app:

- **`--text` and `--lists` write what level 1 does with no edit**, by the same reading of the source: `.ripulText()` on each text with no colour, and the list modifiers. Each leaves its view untouched until a theme names the colour, so the system look cannot move. A text the tool could not tell was coloured from another file takes the theme's ink under the theme: look at each themed screen, and take the line off that text. A list row outside any `Section` needs `.ripulThemedListRows()` written on it.
- **It writes `import RipulThemeKit`** in each file it left calling an accessor, unless the app has one `@_exported import` of it or of `RipulAgent`.
- **It does not follow the app's own font helper** (`static func serif(…) -> Font`), and with `--named` it leaves `.black.opacity(…)` inside a gradient or a shadow. `check` lists each.
- **`lint` reports a line you added by hand** (a root line, a list modifier) as "the hunk adds and removes different numbers of lines". That is the lint not knowing the line, not a moved value.
- **A zero from `check` is not proof.** It cannot see a bare `.orange` passed to an unlabelled parameter. A new `Text` with no colour is counted only with `--text`.

Finish what `check` lists by the tables in `docs/theming-for-hosts.md` ("Move the call sites" and "What it leaves for you"). A colour that is data (a category's, a chart's, a shade over a photo) takes `// theme-exempt: <reason>` on its line and stays.

## 9. Prove nothing moved

After the last edit, whatever the level:

1. Launch with `-ripul.theme.document system` (or with no theme document in the bundle) and capture every baseline screen again, light and dark.
2. Compare with both baseline sets pixel for pixel. A difference must be in a place where your two baseline sets differed from each other. Anything in the app's own content is an edit that changed the app: find it and fix it. Say how many screens matched exactly, and for each of the others where it differs and why you call that the system's.
3. After level 3, `ripul-theme lint <theme-base>` must have nothing to say about a line the tool wrote; confirm it actually checked the migration.
4. Build Release once. The View Explorer's map is left out of it, and the theme must still load.

## 10. Hand back a ledger

Do not merge. Report, with each line marked measured or reasoned:

- the branch, the recorded starting commit, and what `git diff --shortstat <theme-base>` reads; how many Swift lines changed (none, after level 1);
- the files added: the document, each font with its licence and where it came from, any stand-in for a font that could not be bundled;
- every build command and script that gained `-skipPackagePluginValidation`;
- what follows the theme and what does not, by kind, with a screenshot for each;
- the comparison: how many screens, how many the same, and why each of the others differs;
- every decision you made for the person and every one still open (the app's own colours, dark values you derived, a font you substituted);
- what you did not test: a phone, Dynamic Type, Increased Contrast, right-to-left, an archive.

## Limits to say out loud

- Level 1 rests on how the Swift compiler chooses between two declarations of one name, measured with Swift 6.4 and Xcode 27.1 and not promised by the language. If a compiler changes it, the likely result is a compile error in the app's files, and the cure is to switch the plug-in off.
- Level 1 themes a text by the line it is written on, read from the source at build time. A text whose colour came from somewhere the source does not show on that line's file is themed all the same.
- An app that links only `RipulThemeKit` has no developer console and no View Explorer.
- A theme document cannot ask for a font feature such as lining figures.
- If you are running inside Ripul (you have a `ripul_guide` tool), read its `devices` and `trains` guides before you install a build on a phone or use a simulator another agent may hold.
