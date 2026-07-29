# Tool Collections Editor — in-app reorganisation of progressive discovery

> **Part of the [DevKit Program](../../docs/plans/devkit-program.md)** — an SDK dev surface, peer of the theme editor and View Explorer. See the hub for the map and the surfaces glossary.

> Let the developer of an SDK-consuming app reorganise their tool collections from inside their own iPhone app, against the live tool set of the build in their hand.

**Status:** built 2026-07-28 in `Sources/RipulAgent/ToolCollections/`. Compiles for macOS and iOS. Drag-and-drop *has* since been exercised on device — instrumented runs showed `onDrag` firing while `isTargeted` and the drop handler never did inside a `List`, which is why the editor is built on `ScrollView` + `LazyVStack` (commits `bac467c76`, `6aabddd07`, `e6b1958f3`). The API round trip and post-restart collapse remain unverified — see [Verification still owed](#verification-still-owed).

## Why this surface

Progressive discovery collapses a large tool set into a handful of CategoryTools the model expands on demand. Membership is **curated, not inferred** — someone decides what belongs together (see [progressive discovery in the SDK README](../README.md#scaling-to-many-tools)).

Today that curation happens only in the web dashboard, which is the wrong place for it. The dashboard knows the tools it has previously *seen* through discovery. The device knows the tools this build actually *registered* — every `NativeTool` handed to an `AgentBridge` moments ago, with names and descriptions.

That asymmetry is the whole argument. An app developer holding their phone has better information about their own tool set than the dashboard does, and no way to act on it.

> **The surface model here has been decided, and `RipulToolCatalog` is on its way out.**
> It was a device-side, hardcoded concept in an otherwise data-driven system; the
> resolution is that it becomes an **audience tag** on a unified `RipulToolRegistry`
> (register once, tagged; channels expose a projection). See
> [native-tool-registry](../../docs/plans/native-tool-registry/README.md) — phase 1
> deletes `RipulToolCatalog` and `RipulSessionsConfiguration.endUserTools`. The
> options paper
> ([tool-grouping-rationalisation.md](../../docs/plans/tool-grouping-rationalisation.md))
> is now historical context, not an open question.
>
> ⚠️ **"Surface" in this document means audience** (end-user tools vs developer tools).
> Since 2026-07-28 the SDK also has `AgentConfiguration.surface`, which means something
> different — a named **app area** mapped server-side to a solution context via
> `surfaceContextMap`. Two axes, one word: *audience* is who the tools are for
> (build-time, device-known); *surface* is where in the app the session lives
> (server-resolved). The plan renames this document's axis to **audience**.

## Tool surfaces — read this before anything else

**An embedding app has more than one tool registry, and they are disjoint.** This document's first draft said "the tool set this build registered", as if there were one. That premise was wrong and caused every defect this feature shipped with:

| Surface | Lives on | Contains |
|---|---|---|
| **End-user tools** | the app's agent panel bridge (`AgentView`) | what a user's agent can do — WAC's receipts, rota, pickers |
| **Developer tools** | the console's own bridge (`RipulAgentConsole`) | console logs, screen inspection, theme knobs |

They coexist in one process on different `AgentBridge` instances. Reading one and calling it "this app" made the editor report every end-user tool — precisely the ones worth grouping — as missing.

`RipulToolCatalog` models this: a **named tool surface belonging to one agent**, carrying a plain-language purpose. Both surfaces are organisable, because either agent can carry too many tools. What must never be ambiguous is *whose context is being economised* — so the editor shows **exactly one catalog at a time, never a union**, behind a picker with the purpose stated under it.

Consequences that follow, and are easy to get wrong again:

- A host **declares** its end-user surface (`endUserTools:`); the console does not **register** it *by default*.
  > **Revised 2026-07-29.** The original wording — "registering would hand end-user
  > capabilities to the dev agent" — conflated three layers, and the conflation was the
  > thing to fix. Declaration is for **attribution** and is unconditional. Registration
  > is **absorption**: an opt-in, attributed testing affordance the authenticated owner
  > performs on capabilities they already own (plan phase 2), not a hazard. The hazard
  > is only the *other* direction, and that is now a structural gate rather than a
  > convention: developer-tagged tools have SDK-internal initializers and are filtered
  > out of any `.endUser` channel's `mcp:tools` broadcast and invoke lookup
  > (`AgentBridge.audience`, shipped in phase 0). The valve is deliberately one-way,
  > because the two directions differ in principal and blast radius.
- The SDK synthesises the developer catalog from its own bridge, so a host declares one line, not two.
- Members are **attributed**, not merely counted: "in Developer tools", "web app or other device". "Not in this app" was false in both directions.
- Collections are account-wide and carry no catalog tag, so one **can** span surfaces. The editor scopes the list to collections holding at least one tool of the surface in hand, and puts the rest behind a disclosure — including Ripul's own seeded platform collections (`automation_tools`, `page_interaction_tools`), which contain only web app tools and are not an SDK consumer's concern. The test is content-based rather than an allow-list, so it stays correct for Ripul's own app, where those collections *are* relevant.

## Current state

| Piece | Where | Status |
|---|---|---|
| Collections CRUD API | `chrome-extension/packages/api/src/toolCollections/` | Shipped — `/v1/tool-collections`, Clerk-authed |
| Site-key read path | `packages/api/src/index.ts:1035,1284` | Shipped — collections are **GET only**, resolved via `billingUserId`. (Note: "site keys are read-only" is true *of collections*, no longer of the site-key surface as a whole — `POST /v1/site-key/context` now mints tokens.) |
| Membership matching | `chrome-extension/src/LLM/Tools/CategoryToolMatcher.ts` | Shipped — `explicitTools` ∪ `toolPatterns` |
| Web authoring UI | `chrome-extension/src/logging/SiteToolsTab.tsx` | Shipped — collections dialog incl. name patterns |
| Agent-facing CRUD | `chrome-extension/src/LLM/Tools/ManageToolCollectionToolHandler.ts` | Shipped — `manageToolCollection` |
| SDK client | `ToolCollections/ToolCollectionsClient.swift` | Built — CRUD, `tokenProvider` injection |
| SDK matcher mirror | `ToolCollections/ToolCollectionMatcher.swift` | Built — previews membership before save |
| SDK editor | `ToolCollections/ToolCollectionsScreen.swift`, `ToolCollectionEditorView.swift` | Built |
| SDK agent tools | `ToolCollections/ToolCollectionTools.swift` | Built — list/create/update/delete |
| Registered tool set | `AgentBridge.registeredToolSummaries` | Built — public read accessor |

## Placement and auth

**The editor lives on the console surface**, alongside the sessions list and machine directory — not in the DevTools sheet.

The reason is auth. `RipulAgentConsole.swift:78-90` gates the entire agent screen on `authStore.isSignedIn`: hidden and non-interactive until signed in, with `RipulSignInView` for a genuinely signed-out user. **A full Ripul login is a precondition for the console existing at all**, so by the time a developer is in that surface, a live Clerk token is already in hand and already vended downward via `tokenProvider: { authStore.token }` (`:62`, `:75`).

By contrast `.ripulDevTools(bridge:)` needs only a bridge and carries no login. Putting the editor there would mean building a sign-in gate the console already provides.

> **Do not confuse the two auth contexts in this binary.** The site-key path is **read-only** by design — site keys ship inside the app, so a write-capable one would let any extracted key rewrite the account's collections. That governs the *app's runtime consumption* of collections. The *developer's authoring session* is Clerk-authed and unrelated. Both live in the same process.

## Platform

**iOS only.** The Catalyst build is the Mac client, and under Mac Catalyst `#if os(iOS)` is true while `#if os(macOS)` is false — so Catalyst takes the iOS path for free. Write no `#if os(macOS)` branches; the `NSWindow` variant `DevToolsModifier` carries exists for the native `RipulMac` scheme, which this feature does not serve.

One Catalyst build-time note: sheets present as centred panels, so prefer a full-screen push over a detented sheet.

## Propagation

**Saving requires an app restart to take effect**, and that is accepted rather than engineered around.

Collections reach a site-key app as part of the site-key configuration, resolved at session start and pushed once via `SiteKeyContext` → `siteToolDiscoveryService.setToolCategories`. A restart re-validates and re-pushes. No cache-busting, no live re-push, no new propagation mechanism.

This is affordable because **reorganising is rare and design-time** — the frequent event is a *new tool arriving*, which an existing collection's pattern absorbs automatically, in-session, with no regroup at all.

> **This obliges one UI affordance.** The developer is editing collections inside the very app whose agent consumes them, so a silent successful save is indistinguishable from a failed one — they will check the agent, see the old grouping, and assume the write didn't land. A **"Saved — restart to apply"** confirmation is the entire fix, and it is not optional.

If a plain web view reload turns out to re-resolve the site-key config, that is a cheaper middle ground worth taking during implementation. Do not design around it.

## Components as built

> Design-time names in an earlier draft (`RipulToolCollectionsScreen`, …) did not all
> survive contact; this table is what actually exists. See "Current state" above for
> file paths.

| Component | Role | Precedent |
|---|---|---|
| `ToolCollectionsClient` | CRUD over `/v1/tool-collections`, taking a `tokenProvider` closure | `MachineDirectory`, `CmsClient`, `BuildFeed` |
| `ToolCollectionsScreen` | The editor — collections, membership, pattern testing | `RipulSessionsView` as a console peer |
| `RipulDevToolCollectionTools` | Agent-facing CRUD, same write path as the human UX | `RipulDevThemeTools` |
| `AgentBridge.registeredToolSummaries` | Public read of the registered tool set | new — the raw arrays stay private |

The screen needs both `bridge` (for the live tool set) and `tokenProvider` (for writes) — exactly what `RipulAgentConsole` already has to hand.

### Live pattern testing is the centre of gravity

The editor should lead with **patterns**, not hand-picking, and show match counts and the matched list live against the registered tool set: type `^calendar_`, see *"matches 12 tools"* and which.

This is the "pattern tester" the [original web design doc](../../chrome-extension/docs/features/tools/progressiveToolDiscovery.md) specified and the web dialog cannot build — `SiteToolsTab`'s collection form has no access to a tool list, which lives in a separate picker component. On device it is nearly free.

Match against the **canonical** name the app registered (`get_events`), not the transport-prefixed one (`host_get_events`) — the interceptor strips `host_` / `web_tool_` before matching.

### Agent peer

`RipulDevThemeTools` established that a human editor and the agent should drive the same mechanism, so the same move applies: the developer can *ask* for a regroup from the same device. The semantics already exist in `manageToolCollection` on the web side and should be mirrored, not reinvented.

Gate host-side, matching `RipulDevThemeTools.all(isEnabled:)`.

## Settled decisions

| Decision | Choice | Why |
|---|---|---|
| Placement | Console surface | Login guaranteed; token already vended |
| Auth | Clerk via `tokenProvider` | Site-key writes are correctly forbidden |
| Platform | iOS + Catalyst, no macOS | Catalyst is the Mac client |
| Propagation | Restart to apply | Reorg is rare; frequent case is pattern absorption |
| Scope | Full CRUD | Edit-only forces a dashboard trip for the first action |
| `siteKeyId` | **Not assignable on-device**; default `__global__` | A wrong value makes a collection silently invisible to the interceptor's scoped fetch — the orphan-category failure that hid `iphone_inspect` |
| Shipping | Shipped, host-gated | Consumers enable in TestFlight without a separate debug target |

## Verification still owed

Both builds are clean (`swift build` for macOS, `xcodebuild -destination 'generic/platform=iOS'` — the macOS build does **not** cover the `#if os(iOS)` screens, so the iOS build is the meaningful one). Nothing below has been exercised against a running app:

- A real `GET`/`POST`/`PATCH`/`DELETE` round trip with a live Clerk token.
- That a saved collection actually collapses tools after a restart.
- Catalyst presentation (sheets centre; the editor pushes, but the create sheet does not).

## Known drift risk

`ToolCollectionMatcher.swift` duplicates matching logic the web app owns in `CategoryToolMatcher.ts`. It exists so the editor can preview membership on-device, which the dashboard cannot do — but two implementations of one rule will diverge unless someone notices. **If membership semantics change on the web side, change both.** The Swift file lists the rules it is mirroring so a reader can diff them by eye.

## Open items

- **Team accounts.** The developer writes as `user.sub`; the running app reads via `billingUserId`. Identical for a single-owner account, divergent for teams — verify before a team ships this.
- **Exclusions.** `CategoryConfig` has no `excludeTools` / negative pattern, so "everything matching `^calendar_` except one" means hand-listing. Deprioritised: rare regrouping makes hand-listing a cheap one-off.
- **Deletion semantics.** Deleting a collection returns its tools to the flat list — harmless, but confirm the editor makes that consequence visible.

## Precedents followed

- **Theme framework** (`ThemeEngine`, `RipulStyleKindEditorView`, `RipulDevThemeTools`) — mechanism in the SDK, generic editor, agent tools driving the same engine. Note one simplification: theming needs a host-declared vocabulary (`RipulThemeSpec`), **this does not**. Tool names *are* the vocabulary and the bridge already owns them, so any host registering tools gets the editor for free.
- **DevTools spine** (`DevToolsModifier`) — `.ripulXxx()` modifier, notification/flag trigger, host-side gate.
- **Console sub-components** (`MachineDirectory`, `RipulSessionListModel`) — `tokenProvider` injection over an auth-store dependency.
