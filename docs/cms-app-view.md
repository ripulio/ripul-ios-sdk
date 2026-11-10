# CmsAppView: a CMS site as a whole iPhone app

`CmsAppView` turns a CMS site into an app with iOS's own tab bar. The site's `tabBar` block (on its shell page) gives the tabs. Each tab is its own navigation stack, and all tabs share one load of the site and one data runtime.

Peter, 27 October 2026: "an apps button bar that acts a first class button bar in iOS, that repeat all iOS conventions". The plan is `docs/plans/cms-app-tab-bar.md`. The block, its editor, the web's bar and the `check_site` rules are in `chrome-extension/docs/architecture/cmsTabBar.md`.

**The rule everything rests on:** the bar is the system's `TabView`, never a drawing of one, and nothing restyles its surface: no `UITabBarAppearance`, no background, no shadow. The site's theme may set the tint (when it names a primary colour) and nothing else. On 27 October, WAC's own 3.0.0 builds needed two fixes because an appearance override turned iOS 26's glass bar into a flat white slab, and hiding the bar left a blank band. With the system's own bar, almost every convention below comes from iOS, and keeps up with each release.

Code: `Sources/RipulAgent/CmsRender/CmsAppView.swift` (the view, iOS only) and `CmsTabBar.swift` (decoding, which tabs a person gets, routing, the re-tap rule; on every platform, so it is tested on the Mac).

## The API

```swift
public struct CmsAppView: View {
    public init(
        cmsId: String,
        clientConfig: CmsClientConfig,      // auth, base URL and the app's origin, as for CmsPageView
        visitorSiteKey: String? = nil,      // the site key's publishable key; nil loads as the owner
        hostTabs: [CmsAppHostTab] = [],     // the host app's own tabs
        controller: CmsAppController? = nil,// opens pages from outside (links into the app)
        initialPageSlug: String? = nil,     // a page to open once loaded
        showsDeveloperTools: Bool = false   // the runtime inspector pill on every page
    )
}

public struct CmsAppHostTab {
    public init<Content: View>(id: String, title: String, systemImage: String,
                               badge: String? = nil, placement: Placement = .trailing,
                               @ViewBuilder content: @escaping () -> Content)
}

@MainActor public final class CmsAppController: ObservableObject {
    public func open(pageSlug: String, viewRef: String? = nil)
    public func select(hostTab id: String)
    /// `<scheme>://ripul-page/<slug>`, the link a running record's Live Activity
    /// carries: true when it was one. Call it from the host's `.onOpenURL`.
    @discardableResult public func handle(url: URL) -> Bool
}
```

A site that declares a running record (`action.after.activity`) gets a Live Activity on the Lock Screen and in the Dynamic Island. `CmsAppView` starts, updates and ends it. The host adds a widget extension listing the SDK's `CmsRunningActivityWidget()` (from the dependency-free `RipulLiveActivity` library), `NSSupportsLiveActivities` and a URL scheme. See `chrome-extension/docs/architecture/cmsElapsedTimer.md`.

It works from iOS 17, the SDK's minimum.

WAC Next, with the Account tab the CMS can't provide (it doesn't own sign-in):

```swift
@StateObject private var links = CmsAppController()

CmsAppView(
    cmsId: "cms_1kp9x89jzhvv",
    clientConfig: config,                  // carries origin: "https://wac-next.app"
    visitorSiteKey: wacNextSiteKey,
    hostTabs: [
        CmsAppHostTab(id: "account", title: "Account", systemImage: "person.crop.circle") {
            List {
                Section { LabeledContent("Signed in as", value: session.email) }
                Button("Sign out", role: .destructive) { session.signOut() }
            }
            .navigationTitle("Account")
        }
    ],
    controller: links
)
.onOpenURL { url in links.open(pageSlug: url.lastPathComponent) }
```

**A host tab gives way to a site tab whose page slug is its id** (`CmsAppLayout.shownHostTabIDs`), and a remembered host tab then opens that site tab (`rememberedTab`). So a site can take over a screen the app drew, by configuration alone: WAC Next's Account becomes the site's `account` page once the tab bar lists it for the iPhone. While the site isn't loaded every host tab stays.

**`hostActions`** (`[String: @MainActor () -> Void]`) are what the app does for a card's `open: { host: "<name>" }`, such as `"signOut"`. A part naming a name the app doesn't handle is left out (`docs/architecture/cmsCards.md` in chrome-extension). A `"signOut"` action also gives the site's account menu (a `userAccount` block, `CmsRuntime.onSignOut`) its Sign out.

**The toolbar** (`tabBar.toolbar`, 3 November 2026). Nav items, each with an embedded `block`, drawn at the trailing end of the navigation bar on every tab's first page, in order, for the people who may see them (`visibility`, `requiredRoles`, `platforms`). It is where a website's top bar keeps its bell and account avatar, and where Apple's own apps keep the account. The web draws nothing for it. wac for business carries WAC's bell (`notificationCentre`) and account menu (`userAccount`) there.

**The shell's record cursors.** On the web the shell is always mounted, and a nav block's header card (`headerQuerySlug`) selects its first record, so pages that wait on that selection load on any page. `CmsAppView` draws no shell, so it keeps those cursors itself: it loads each shell `sidebarNav` or `topNav` header query and selects its first record while nothing is selected, as the native drawer does while closed. WAC's business pages wait on `@companies_select.company_id` this way.

## Signing in with the site's own accounts

A site whose members sign in with its own identity provider (the site key's `portalAuth` 'clerk', bring your own identity provider: WAC's business accounts at clerk.wac.rocks) signs them in on its own website. An app sends them there in the system's sign-in sheet, with no web view anywhere, and everything after the sign-in is native (`CmsPortalSignIn.swift`; the worker's side is `packages/api/src/siteKeys/nativeHandoff.ts` in chrome-extension, an authorization code with PKCE, RFC 7636):

- **`CmsPortalSession(siteURL:providerKey:siteKey:redirect:keychainService:)`** is the sign-in. `signIn(using:)` takes the view's `@Environment(\.webAuthenticationSession)` and opens `<site>/portal-session?pk=…&siteKey=…&redirect=…&challenge=…` in it.
  - The page (chrome-extension `public/portal-session.html`) signs the person in with the provider on the site's own address. It then asks the worker for a one-time code (60 seconds, used once, bound to the redirect and the S256 challenge) and sends the browser to the redirect with it.
  - The app trades the code and its verifier (`POST /v1/site-key/native-handoff/exchange`) for a session of its own: `rns_…`, 30 days, revocable. It is kept in the Keychain, readable after the first unlock, on this device only.
  - The browser session is private (`.ephemeral`): iOS asks nothing before the sheet opens (a shared session first shows "…Wants to Use … to Sign In. This allows the app and website to share information about you"), and nothing of Safari's carries over. The app's own session makes a sign-in rare.
  - `state` is signed out, signing in or signed in (the member's id and email); `token()` gives the session while it lasts; `signOut()` ends it on the server (`DELETE /v1/site-key/native-handoff/session`) and in the Keychain, and the next sign-in asks for an account again (`prompt=login`). `sessionEnded()` forgets a session the server no longer takes.
  - Failures are `CmsPortalSignInError`: `cancelled` (the person closed the sheet), `refused` (the worker's own words) or `failed`.
- **The site key must list the redirect** (`portalAuth.nativeRedirects`, a custom scheme or https), or the page and the exchange refuse it ("Signing in to the app is not on for this site"). WAC's business key lists `wacbusiness://portal-signed-in`.
- **`CmsClientConfig.portalTokenProvider`** sends the session as the Bearer. With a `visitorSiteKey`, the loader loads as a member (membership from `/v1/site-key/me`, the publishable key in each body), as it does for opaque app credentials. The worker takes the session as the same member the provider signed in (its `sub`) on query, mutation and view runs, `/v1/site-key/me`, files and images, on whichever of the site's keys a route resolves to. No token fails the request; it never runs as anyone else.

Why a handoff and not the provider's own API: WAC's Clerk instance has its Native API switched off (`native_api_disabled`, checked 3 November 2026), so only a browser on the site's own address may hold its sessions. Until 3 November evening the app held that session in a hidden web view and signed in through the site's page in an embedded one, with Safari's browser name so Google accepted it; Google refuses OAuth in embedded web views, and getting round that risks the client being blocked, so the Wac > Cms coordinator chose this handoff. The tests are `CmsPortalSignInTests` (RFC 7636's vector, the addresses, the code, the answers).

A host tab's content sits in a navigation stack of its own, so `.navigationTitle` and `NavigationLink(value:)` with `navigationDestination` work in it. Its accessibility identifier is `tabbar.<id>`.

## What it draws

- **Loading:** the site loads once (`CmsPageLoader`, the same path as `CmsPageView`: owner, anonymous visitor or opaque member). Until then it shows the same spinner, error with Retry, or "No access" as `CmsPageView`.
- **While the site isn't loaded, the host's tabs stay.** That covers loading, a failed load (offline at launch) and a refusal (a member whose session ended elsewhere, so the site answers "No access"). With host tabs, the system tab bar shows one status tab in place of the site's tabs, beside the host's own. The status tab holds the status view and its Retry, and is titled by `statusTabTitle` (default "Home") with `statusTabSystemImage` (default `house`), identifier `tabbar.status`. So a host's Account tab, with Sign out, is always reachable. A host tab chosen there is still the selected tab once the site loads; the status tab is never remembered. Without host tabs, the status view shows alone, as before. This was found in WAC Next on 27 October 2026: Rails keeps one session per user, so signing in elsewhere left the app on "No access" with Sign out out of reach.
- **Tabs:** one per visible `tabBar` item, then the host's tabs before (`.leading`) or after (`.trailing`) them. Each tab is a `NavigationStack` whose first page is the item's page.
- **Pages** are drawn on their own, without the shell: `CmsAppView` replaces the shell, so the shell's other blocks (a top nav, a sidebar) are not drawn. A `pageOutlet` that a tab's page contains shows its empty message.
- **No tab bar:** a site without a `tabBar` on its shell shows its landing page in one stack. Links push onto it; a link to the landing page pops back to it. `initialPageSlug` and an early `CmsAppController` request are routed there too (before 27 October 2026 a site with no tab bar dropped them).
- **One runtime:** queries, selections and parameters are shared by every tab. A mutation run in one tab refreshes the queries it names wherever they are shown.

## Who sees which tab

The same rules as the other nav blocks, and the same as the web:

- `canViewNavItem` (`visibility`, `requiredRoles`; designers see everything);
- the tab's page must be one the person can open (page visibility, `CmsPageVisibility`);
- `platforms: ('web' | 'native')[]` (unset is both): an item whose list leaves out `native` is skipped, such as wac-app's web-only Account tab, which would otherwise sit beside WAC Next's own Account host tab. Tab ids are by page, so the other tabs keep their order and the remembered tab still opens. A remembered tab that was skipped falls back to the first tab;
- an item without a `targetPageSlug`, a heading, a slot item (`slotId`), and a second tab for the same page are left out;
- the fields a tab doesn't use (`children`, `url`, `actionType`, `block`, `iconOnly`, the `divider` flag) are ignored, never acted on: an item that names a page the person can open is a tab;
- an empty label shows the page slug; an unknown icon key shows `doc.text`.

## Routing

Links inside a page (a nav item, a drill link, an action that opens a page) and `CmsAppController.open(pageSlug:)` follow one rule (`CmsAppNavigationState.open`):

1. **A tab's first page** selects that tab and pops it back to that page, since the link names that page.
2. **Any other page** the person can open is pushed onto the selected tab's stack, with the system back button and the swipe from the left edge. When a host tab is selected, it is pushed onto the first site tab instead, since a host tab's stack belongs to the host.
3. **The page already on top** is not pushed again.
4. **A page the person can't open** is ignored, as a dead link is on the web.

`viewRef` (`<gridSlug>:<viewId>`) rides the same channel as a nav item's `targetViewRef`. Requests made before the site has loaded run once it has. `initialPageSlug` is routed the same way after the selected tab is restored.

## The conventions, and how each is met

| Convention | How | iOS |
|---|---|---|
| The glass bar, the classic bar before it, dark mode, Bold Text, Increase Contrast, Reduce Transparency, right to left, the large label on a long press at the largest text sizes | The system's `TabView`, unstyled | all |
| Each tab keeps its place | `TabView` keeps every tab's view alive; each stack's path is kept in state per tab | all |
| Tapping the selected tab pops to its first page; tapping again scrolls to the very top | The selection binding sees the same tab written again; `CmsAppReselect` pops when the stack is deeper than the first page, else scrolls to the top. "The top" is Apple's: the large title open again. A probe finds the page's `UIScrollView`, keeps the largest top inset seen at the current width (the inset with the title open), and scrolls to minus it. `ScrollPosition`'s top edge and a top anchor both stopped under the collapsed inline title (bar 54 pt against 105 pt open) | all |
| Large titles | `.large` on each tab's first page, `.inline` on pushed pages | all |
| Badges | The item's `badge`, tokens resolved (`badgeText(runtime:)`: blank, "0" and unresolved tokens show none), through `.badge` | all |
| More than five tabs | The system shows four and More on an iPhone, the rest listed under More (a host tab too) | all |
| Sidebar on iPad and Mac | `.tabViewStyle(.sidebarAdaptable)` | 18+ |
| Accessory | `tabViewBottomAccessory` on iOS 26; a plain strip above the bar (`safeAreaInset`, `.bar` material) before | 26 / 17–25 |
| The bar shrinking on scroll | `tabBarMinimizeBehavior(.onScrollDown)` when `minimizeOnScroll` (default on), `.never` when off. Shrunk, the bar is the selected tab alone beside the accessory; the first tap on it brings the bar back, and only then does a re-tap pop or scroll | 26 |
| The chosen tab remembered | `@SceneStorage("io.ripul.cms.app.tab.<cmsId>")`, with the same key in `UserDefaults` behind it: iOS drops a scene's saved state when the app is killed, and the app then reopened on its first tab. A stored tab that no longer exists falls back to the first | all |
| Links into the app | `CmsAppController.open(pageSlug:)` (routing above) | all |
| VoiceOver | The system's: "Shifts, tab, 1 of 3" | all |
| UI-test identifiers | `tabbar.<page slug>` for site tabs, `tabbar.<id>` for host tabs: `.accessibilityIdentifier` on the tab's `Label`, which SwiftUI carries to the bar's button. (A first version set them on the UIKit items and lost the race with SwiftUI rebuilding them.) | all |
| The tint | `.tint` from the theme's primary, only when the theme names one | all |
| iOS 17 | `.tabItem` and `.tag` in place of `Tab` | 17 |

The page overlays the shared runtime drives (the drawer a sidebar layout opens, an `agentChat`'s floating button) are drawn in the selected tab only, over its stack and under the bar. The screen edges belong to the navigation stack: pages in `CmsAppView` take no edge swipes of their own.

## In CmsPageView and CmsPortalMenu

- **`CmsPageView`** draws a `tabBar` met in a page (a shell drawn the old way) as nothing, out of the stack's flow. Tabs come from `CmsAppView`.
- **`CmsPortalMenu.tabs`** hands the tab bar's tabs, filtered the same way, to a host app that draws its own chrome. A site whose only nav is its tab bar also contributes the tabs as `items`. A site without a tab bar behaves exactly as before (`tabs` is empty).

## The feature button

`tabBar.featureButton` is an outsized, branded button in a slot of the bar that runs an action instead of opening a tab: WAC's centre WAC in / WAC out button, made general. The shape, the rules and WAC Next's configuration are in `chrome-extension/docs/architecture/cmsTabBar.md`, "The feature button". The plan, with what WAC's own app does: `docs/plans/cms-tab-bar-feature-button.md`.

Code:
- `CmsTabBarFeature.swift`: decoding, variants, the slot. It builds on every platform and is held to `cmsTabBarFeature.cases.json` by `CmsTabBarFeatureTests`.
- `CmsTabBarFeatureView.swift`: the disc, its tracker and its runner.
- `CmsAppView.swift`: the reserved tab and the selection rule.

**How it is drawn, and why.** The system's tab bar stays exactly as it is.
1. **The reserved tab.** The slot is a real `Tab` in the `TabView` (`CmsAppTabID.feature`), with the button's label and icon, and the identifier `tabbar.feature`. So everything the system does with tabs works for it:
   - VoiceOver ("WAC in, tab, 3 of 5");
   - the iPad and Catalyst sidebar, and iPad's top tab bar, where it is a row or segment with its own label and icon;
   - More;
   - Full Keyboard Access, and the large label on a long press at the largest text sizes.
   - It has a label, so iOS 26 gives it a full slot. WAC's own app used an empty item, which shrank to zero width until it was selected.
   - **On a bottom bar its title is empty, and its icon carries the label.** The disc covers the reserved tab, but a label wider than the disc showed at its sides ("Finish shift" read "F … t" on Peter's phone, 31 October 2026). iOS 26 and 27's glass bar ignores an item's title colour and its own appearance, so `featureTitle` leaves the title empty at compact width. A bar names a button with no title by its image, and an SF Symbol's own name for `circle.circle.fill` is "Circle inside a filled circle". So there the icon is the symbol drawn into a bitmap that carries the button's label (`CmsFeatureTabIcon`, one image per label, kept), and VoiceOver reads "Finish shift". The slot keeps its full width (it still has an icon). A sidebar shows the title, as before.
   - **What didn't work, so it isn't tried again.** The `Tab`'s and the `Label`'s own `accessibilityLabel` don't reach the bar's button. Setting `accessibilityLabel` on the button through UIKit worked, but cost every tab its `tabbar.<slug>` identifier. A fresh `UIImage` of the same symbol kept the first label: SwiftUI takes two images of one symbol as equal and doesn't update the item.
2. **The reserved tab is never selected.** The selection binding sees `feature`, runs the action and keeps the selected tab, so the other tabs keep their stacks and the remembered tab.
   - **UIKit doesn't select it either.** The binding putting the old tab back came too late: UIKit had already selected the reserved tab, so the selected tab's screens left the window and came back. A page pushed then never got its safe area. WAC Next's On shift, opened after WAC in, drew its timer under the status and navigation bars (3 November 2026), and later pushes and disc taps did nothing until a relaunch. So the tracker puts `CmsFeatureTabGuard` in front of the tab bar controller's delegate (SwiftUI's), passing everything on but answering `shouldSelect` / `shouldSelectTab` with no for the reserved tab and running the action instead (again if SwiftUI replaces the delegate; logged as "tab bar feature guards its tab from selection"). Checked on the iPhone 17 simulator as user 64: On shift's safe area went 0 → 116 after WAC in, where before it stayed 0.
3. **The disc.** It is drawn over the `TabView` at the reserved tab's place, which is found in one of three ways, best first. Nothing depends on a private class or on accessibility being on.
   - **`button`:** the reserved tab's own button. The tracker takes the tab bar controller's own chrome (the tabs' screens skipped; the iPhone Duo's strip sits outside the `UITabBar`) and its `UIControl`s. It keeps the row most of them share, and the buttons near that row's usual size: iOS 27.0 keeps a 48 pt compact copy of the first tab on the same row as the 85 pt buttons. Copies at one place are merged, and the buttons are taken in bar order. With as many buttons as tabs, the reserved one is at the slot's index. Its accessibility label confirms it when there is one.
   - **`neighbours`:** with one button fewer (the reserved tab drawn at no width), midway between its neighbours' inner edges, as WAC's own app places its disc.
   - **`geometry`:** the last resort, from the window alone. iOS 26's floating bar is inset 25 pt from each side, with its buttons' middle 18 pt above the bottom safe area, and the bar is shared equally among the tabs, so a centre slot is the screen's middle.
   - **Why not the identifier or the label.** SwiftUI puts a tab's `.accessibilityIdentifier` on its accessibility element, not on the view. Its accessibility label is filled in only while an assistive technology is on. The simulator's device tools turn that on, so the first build found the button by its label on the simulator and nothing on Peter's iPhone 17 Pro Max (iOS 27.2), where only the plain reserved tab showed (30 October 2026).
   - **Searching again.** Until a button is found, the search repeats after 0.25, 0.5, 1, 2, 4 and then every 8 seconds, twelve times. A later search only ever upgrades the anchor, so a bar caught mid-layout can't move a placed disc. When UIKit rebuilds the bar's buttons, so that the anchor's views go, the search starts again.
   - **Holding still through a tab change.** On every tab change UIKit hands back a mid-update place for the button for about 33 ms: x 201 → 180 and y 822 → 31, then back (iOS 27.0). The disc flicked left on each tab change on Peter's phone (iPhone 17 Pro Max, iOS 27.2, 31 October 2026). So a place more than 12 pt from the one shown is followed only once it has held, within 2 pt, for 80 ms (`CmsFeatureSteadiness`, tested in `CmsFeatureSteadinessTests`). Smooth movement, such as the bar minimizing or the accessory, is followed at once; a real jump, such as a rotation or a new size, 80 ms later. A debug build logs every placement with `-RipulFeatureTrace YES`, in the app's defaults or as a launch argument, under `io.ripul.sdk` / `featureButton`.
   - **Checking the fallbacks.** On a Debug build, `-RipulFeatureIgnoreLabels YES` finds the button as a phone without VoiceOver must, and `-RipulFeatureForceAnchor neighbours|geometry` tries a fallback on purpose. All three put WAC Next's disc in the same place on the iPhone 18 Pro Max simulator.
   - **The log.** `log stream --predicate 'subsystem == "io.ripul.sdk" && category == "featureButton"'` says how the disc was placed (button, neighbours or geometry, how many buttons for how many tabs, whether labels were on) and, when it first shows, whether its picture was ready.
4. **Following the button, and sleeping when nothing moves.**
   - **The display link** reads the button's presentation frame and its opacity up the chain to the window. It runs only for a moment after something may have moved.
   - **What wakes it:**
     - key-value observation of `position`, `bounds`, `opacity`, `isHidden` and `transform` on every layer from the button up to the window. iOS 26 minimizes the bar on a container well above the button, so watching only the button missed it;
     - a hidden view in the `UITabBar` that reports its layout;
     - the overlay's size, size class and Dynamic Type size, and the selected tab.
   - **Measured idle on the iPhone 18 Pro simulator (iOS 27.0), WAC Next on Records,** CPU time over 60 seconds of nothing:
     - 0.00 s with the button left off the iPhone;
     - 0.00 s with the disc shown, and no display-link start in that minute;
     - one earlier run read 0.07 s, measured straight after signing in.
5. **When the disc shows:** only while the button is visible, in a horizontal bar along the bottom of the window.
   - **Minimized:** as the bar shrinks on scroll, the button's chain reaches opacity 0 and the disc goes with it. It comes back with the bar. Checked on the simulator.
   - **A sidebar or iPad's top bar:** no disc. The tab shows its own label and icon, and selecting it runs the action.
   - **A vertical strip** (the iPhone Duo's outer screen): the disc fits the strip's width, with no lift.
6. **Accessibility.** The disc is hidden from VoiceOver, because the reserved tab is the accessible element. A shown label scales with Dynamic Type up to 16 pt.
7. **The accessory.** With one set, `lift` is drawn as 0, so the disc doesn't cover the accessory.

**What it does.**
- **Its actions:** the cards' rules (`CmsTabBarFeatureRunner`).
  - `run` fills `{column}` inputs from the query's first row. An input left out is asked for in the mutation's own sheet: `CmsRecordFormSheet` when the mutation has a form, else `CmsActionInputSheet`.
  - A confirm shows as an alert titled with the button's label. The mutation's success message shows as a short note at the top.
  - `open` opens a page or tab through the runtime, an address through `openURL`, or a record form through `CmsRecordFormPresenter`, which follows the form presentation setting.
- **A menu:** the system's `Menu` on the disc (native-first). Its rows are the action button's menu rows, mapped to card actions (`mutation`, `navigatePage`, `openUrl`, a `form`), and a placeholder row says it is coming soon. The web draws the action button's glass panel instead.
- **Variants** read the runtime's rows for the button's queries, loaded when the overlay appears, so WAC in turns into WAC out after `wac_in` refetches `current_shift`.
- **Pictures:** `CmsFeatureImageStore` keeps them in memory and on disk (Caches, `io.ripul.cms.featureButton`), so every launch after the first draws at once. Every variant's picture is fetched up front. Until a picture is ready, the disc shows its fill alone, so it is never invisible. PNG, JPEG, WebP and HEIC work. **SVG does not draw**, and `check_site` warns about it.

**Matched to WAC's own bar (30 October 2026).** I compared WAC Next on the iPhone 18 Pro Max simulator (iOS 27.0, 3x) with Peter's screenshot of WAC on his iPhone 17 Pro Max, at the same scale. Both discs are about 164 px (55 pt) across, sit at the same place, centred in the pill and not raised, and use the same artwork: WAC's own SVGs drawn to PNG, at `size: 55`.

**Checked on 30 October 2026, iPhone 18 Pro simulator (iOS 27.0), WAC Next as test user 918:**
- the WAC mark centred on the glass bar between Records and Jobs;
- a tap opened the WAC in sheet, a job was chosen, and Save WACed in, after which the mark turned into WAC out;
- the bar minimizing on scroll took the disc away, and scrolling back brought it back;
- WAC out asked to confirm and WACed out, and the mark went back to WAC in;
- the test shift was then deleted from its record form.

**Press and hold (`hold`, 30 October 2026).**
- **The ring:** `CmsFeatureHoldDisc` draws a ring in the hold's palette role round the disc. It fills over the hold's seconds, with a glow that grows, and gives a haptic at the start and a success haptic at the end. Then it runs the hold's action through the runner with `skipConfirm`.
- **Tap and hold together:** a tap still runs the button's own action (`onTapGesture` beside `onLongPressGesture`).
- **VoiceOver:** the disc is hidden from VoiceOver, so the reserved tab's `Label` carries `.accessibilityAction(named:)` with the hold's label, and that runs the hold too.
- **Checked:** in WAC Next, holding the "wac out" disc for 1.2 s WACed out with no dialog.

**Limits:**
- Not run on Catalyst, rotation, an iPad or the Duo's strip (the paths are written, but only the iPhone was checked).
- A menu from the reserved tab itself (VoiceOver, the sidebar) opens nothing: the system `Menu` belongs to the disc.
- Hold to WAC out, as WAC's own app has it, isn't built: a confirm takes its place.

## Limits

- A page's own shell (`shellPageId`, `hideShell`) is not drawn in `CmsAppView`: every page is drawn on its own.
- A host tab's re-tap pops its stack; scrolling a host page to the top is up to the host.
- More's list (tabs five and later on an iPhone) does not carry the `tabbar.<slug>` identifiers; its rows are found by their labels.
- Checked on simulators with iOS 26.4 and 27.1 only. The iOS 17 path (`.tabItem`) and the iOS 18 to 25 accessory strip compile, but no simulator with those versions was installed to run them.
- One floating chat button and one drawer at a time, in the selected tab: they come from the shared runtime, as on the web.
- The selected tab is restored per scene, not per account.

## Tests

- `Tests/RipulAgentTests/CmsTabBarTests.swift`, 15 tests (`swift test --filter CmsTabBarTests`): decoding (items, accessory, `minimizeOnScroll` and its default), finding the bar on the shell only, who sees which tab (visitor, member, role, designer; dropped items; ignored fields), identity and icon fallbacks, the routing rules (push, a tab's first page, the page on top, unknown pages, from a host tab, restoring the selected tab), the re-tap rule, `CmsPortalMenu`'s tabs, the block drawing nothing in a page, the layout while the site isn't loaded, and the per-site tab memory.
- `Tests/CmsAppViewHarness`, 7 UI tests (XCUITest), passing on an iPhone 17 Pro simulator with iOS 26.4 on 27 October 2026. Run with `bash Tests/CmsAppViewHarness/run.sh <simulator udid> [screenshot dir]` on a borrowed simulator. A small host app opens the scratch site as its anonymous visitor, with an Account host tab. The tests check: the identifiers, the system label, the selected tab, the accessory and the large title; More holding the tabs after the fourth, the host tab included; each tab keeping its stack; a re-tap from two pages deep popping to the first page, then (after the shrunken bar is brought back) a re-tap scrolling Home to the top with its navigation bar back at its large-title height; with a key the server refuses (`--refused`), a status tab with Retry beside an Account tab whose Sign out can be reached; a link to a tab's first page selecting that tab; and the chosen tab coming back after the app is killed and relaunched. XCUITest does not see the badge on iOS 26.4; the screenshots show it.
- On a simulator: the CMS Test Bed (`CmsBrowserView`) has **Open as app** under each site, which opens it in `CmsAppView` with a host tab, "Test Bed". `defaults write io.ripul.app io.ripul.cms.testBed.autoOpen "app:<cmsId>[|<pageSlug>[|<pk_…>]]"` opens a site that way at launch (with a publishable key, as that key's visitor). On the iPhone Duo simulator (iOS 27.1, a regular width) the bar showed as the system's side rail, with all seven tabs and the accessory below; switching, keeping place, re-tap pop and scroll, a link selecting a tab and the host tab were all driven there by hand. The scratch site is `tab-bar-iphone-scratch` (`cms_yiqxgp66pbjs`): six tabs (so More), a badge on Inbox, an accessory, a long Home page, and links that push.
