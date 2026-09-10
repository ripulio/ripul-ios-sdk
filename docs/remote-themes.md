# Backend-hosted themes

Ripul can serve the complete JSON theme as a public runtime manifest. An app starts
immediately from its last valid server theme, or its bundled `Theme.json` on first
launch. It refreshes in the background at launch and on foreground entry. A valid
server response replaces the whole document, including host-specific settings;
it is never merged over a stale local editor override.

## Connect an app

After configuring the engine, before creating the first screen:

```swift
RipulThemeEngine.configure(myThemeSpec)
try RipulThemeEngine.followRemoteTheme(
    at: RipulRemoteThemeClient.hostedURL(themeID: "my-app-v1")
)
```

Handle the thrown error in your startup code; it means the local fallback could
not be loaded or decoded. Network failures never throw from this startup call.

If your app owns additional fields (fonts, metrics, screen settings, tips), pass
one callback that decodes the complete document and adopts it through your existing
theme provider. Decode and validate **before** mutating any live state:

```swift
RipulThemeEngine.configure(myThemeSpec)
MyThemeProvider.bootstrapFromEngine()
try RipulThemeEngine.followRemoteTheme(
    at: RipulRemoteThemeClient.hostedURL(themeID: "my-app-v1")
) { data in
    let theme = try JSONDecoder().decode(MyTheme.self, from: data)
    MyThemeProvider.applyServerTheme(theme)
    // This updates the host's current theme, then calls
    // RipulThemeEngine.adopt(theme.engineDocument) to notify/repaint consumers.
}
```

The host does not need to instrument individual views for this loading change.
Existing theme consumers continue using their usual resolution and theme-change
notifications. UIKit tab items and supported app-owned labels also support automatic
text overrides through the app-wide instrumentation described below.
SwiftUI consumers still need the existing theme environment dependency to refresh.

`RipulRemoteThemeClient` is also available independently of the UIKit engine for
hosts that already have a complete theme loader (including native macOS). Retain
the client, call `start()` once, and call `refreshInBackground()` on foreground entry.

## Publish a manifest

`GET https://llm-proxy.ripul.io/v1/app-themes/<id>` requires no token, user login,
site key, or signature. It returns the original document shape, with `ETag` and
conditional `304 Not Modified` support. Browser reads support wildcard CORS.

`PUT https://llm-proxy.ripul.io/admin/app-themes/<id>` takes the complete JSON object
as its body and uses existing Ripul admin authentication (`admin:manage_site_keys`).
Runtime apps never need publishing credentials. IDs allow letters, digits, dots,
underscores and hyphens (128 characters maximum); manifests are limited to 512 KiB.

From a terminal with `RIPUL_ADMIN_TOKEN` set to a current Ripul admin session token:

```sh
node tools/publish-theme.mjs my-app-v1 /path/to/Theme.json
```

Publishing replaces the document atomically, so omitted keys are removed. Use
separate IDs for incompatible app schemas or release channels. The server stores
the host's JSON without imposing an SDK-specific schema; the app's callback must
validate the schema it supports. Keep the bundled file as a known-good fallback.
To roll back, publish the previous complete document under the same ID.

## Runtime behavior

- The startup call performs no network wait. It applies local JSON immediately.
- Valid server themes are cached atomically under Application Support, isolated
  by the full source URL. Cache files are independent of editor preview storage.
- Timeout, offline, HTTP errors (including 404), invalid JSON and host decoding
  failures retain the last valid theme. They never cache an error response.
- Requests time out after 10 seconds and coalesce while a refresh is in flight.
- Foreground entry fetches updates; there is no continuous polling or push stream.
  A foreground app can explicitly `await RipulThemeEngine.remoteTheme?.refresh()`.
- Local editor changes are previews. The next successful refresh restores server
  authority, even on a 304. `restoreAuthoritativeTheme()` resets immediately to the
  last valid server theme (or bundle when no server theme has been accepted).
- `origin` and `lastError` on the remote client expose loading diagnostics.

Backend deployment requires migration `0044_create_app_themes.sql` before publishing.

## Edit and publish on iPhone

The shared agent screen offers **Solution management → Theme** when the host has
registered theme kinds or connected a remote theme. It lists every registered scope, including elements not
currently mounted. Search finds names, paths, IDs and current text; **Text elements
only** filters the list to kinds with free-text knobs. Selecting a row opens native
controls backed by the same engine mutations as View Explorer and the in-app editor.
It also discovers identified UIKit tab items and app-owned labels with a reliable
identifier or stored view property. Reused labels additionally need a row context,
as described below. User-entered record data is not inferred as a theme target.

**Theme document** is a native text editor for the complete JSON. **Apply to app**
validates it through the host's existing full-document callback before previewing.
Both routes feed one local draft. Drafts, including temporarily invalid JSON, survive
closing the editor or a failed publish, isolated per app and theme URL. Foreground
refresh is paused while this editor is open so it cannot replace an in-progress
preview. Closing resumes ordinary server refresh; the unpublished draft remains
available when the editor is reopened.

**Review & Publish** opens a native before-and-after review, grouped into text,
colours, styles and other settings. Names come from the app's existing vocabulary
and scope descriptors. Label overrides are compared individually by their selector,
so adding or reordering labels does not turn the list into one JSON change. Text
highlights changed words; colour swatches resolve against each document separately.
Missing overrides, empty strings and explicit nulls remain distinct. When available,
the app's current default wording is shown and labelled as **App default**.

Search and filters help find changes; the publish count always includes the entire
remaining draft. Open a change for its full values and target details. Structured
host fields appear as labelled properties and list items. **Discard this change**
restores only that value from the review baseline and validates the resulting draft
through the host. **Undo** restores the previous draft, provided no intervening edit
has changed it. Both operations update the app preview and save the durable draft.

The final confirmation names the destination theme and the number of changes.
Publication sends the exact confirmed document; a changed draft must be reviewed
again. Success has an explicit completion screen, and failures retain the draft.
Publishing uses
the signed-in Solution Management account and requires the existing admin permission.
The full document is sent, including host-specific sections. The server compares the
reviewed ETag atomically (`If-Match`), or uses create-only `If-None-Match: *` for the
first publication. A stale draft receives HTTP 412 and is retained. **Reload server
version** explicitly replaces the draft after confirmation. Network/authentication/
validation failures leave the draft available to retry.

After successful publication, the phone adopts and caches the acknowledged document;
other apps following the theme get it on their next refresh. Inline edits made before
opening this editor are included from the current engine state. Hosts that mutate
extra fields outside the engine may set `RipulThemeEngine.exportThemeDocument` to
export their complete current JSON, preserving unknown sections in the optional draft
base passed to the closure. Otherwise the SDK overlays its current slice on
the complete captured document and preserves all other host fields.

Hosts can embed `RipulThemeManagementScreen(baseURL:tokenProvider:)` directly; it owns
its native navigation stack. A hosted theme URL with `/v1/app-themes/<id>` enables
publishing through the host's usual `/api/admin/app-themes/<id>` service. Runtime theme
reads remain public and never carry publishing credentials.

## Automatic UIKit tab titles

Call `RipulThemeInstrumentation.install()` once at launch, alongside the app-wide
theme connection above. Existing `UITabBarItem.accessibilityIdentifier` values are
the bindings. There is no per-item SDK registration or theme lookup in title code.
An item without an identifier needs a stable identifier before it can be targeted;
the adapter never uses its current wording, screen coordinates, or tab position.

For example, WAC already sets `tabbar.legalHub` on its Legal hub tab. In **View
Explorer → Edit**, change **Tab title**, then **Save to theme draft**. Open **Solution
management → Theme → Review & Publish** to review and publish that complete draft.
The same tab can be found directly in Theme by searching its title or identifier.

```json
{
  "nativeTextOverrides": {
    "tabBarItemTitles": {
      "tabbar.legalHub": "Help"
    }
  }
}
```

This section lives alongside the existing host theme fields. The SDK reads and
exports it even when the host's typed theme ignores unknown JSON fields. It uses
public `UITabBarItem.title`; UIKit's internal tab-button views are never modified.
Title-before-identifier construction, later title assignments, reordered tabs,
and recreated items are supported. Removing an override restores the most recent
title supplied by the app. Empty strings intentionally hide the title. Duplicate
identifiers among live tab items disable the ambiguous override and editor row.

The registry holds items weakly. Hooks run on item title/identifier assignment,
tab item replacement and attachment; theme changes update the tracked items.
Installation performs one discovery walk for tabs already in a window. There is
no continuous view scan, timer, or per-frame theme lookup. Explorer trial edits
are temporary; saved drafts survive closing and server refresh without gaining
runtime authority until published. The adapter covers UIKit tab items, including
their rendered descendants in View Explorer, not arbitrary SwiftUI text.

## Automatic UILabel text

The same `RipulThemeInstrumentation.install()` hook also supports app-owned
`UILabel` text. View Explorer shows **Label text → Save to theme draft** for a
reliably identified label. Solution Management discovers editable labels and
lists saved selectors even when their screens are not loaded. Tab titles and
labels share one editor, draft file, complete-document export, and publication path.

Selectors use reusable strategies, with no host-specific class names in the SDK:

1. An existing label accessibility identifier, scoped to its view controller.
2. The owning custom view/controller type and stored view property (including
   storyboard outlets). Custom views in app frameworks are supported too.
3. For table/collection cells, a row scope in addition to the label anchor:
   an existing row identifier, or bounded reflection of plain enum cases stored
   in the row's value-model fields. All captured conditions must match. The SDK
   does not infer row identity from index paths, coordinates, the current text,
   arbitrary model strings, or enum associated values.

For example, a shopping app can capture a promotion subtitle without changing
its normal `subtitle.text = model.copy` assignment:

```json
{
  "nativeTextOverrides": {
    "labels": [{
      "selector": {
        "screen": "StorefrontScreen",
        "ownerType": "OfferRow",
        "property": "subtitle",
        "row": {
          "ownerType": "OfferRow",
          "enums": [{ "path": ["model", "kind"], "value": "promotion" }]
        }
      },
      "text": "Share an offer"
    }]
  }
}
```

When a row lacks discoverable context, configure one central callback alongside
the existing app-wide hook. Individual labels still need no SDK lookup:

```swift
RipulThemeInstrumentation.labelRowContextProvider = { row in
    (row as? ProductCell)?.representedCategoryID
}
```

The provider supplies row identity; the label still needs an existing identifier
or stored property. Selectors based on class/property names must be recaptured
when those names change. Prefer semantic accessibility IDs when already available.
If multiple labels match in one screen, or competing rules target one label, the
runtime keeps app text rather than choosing an arbitrary winner. Separate screen
instances can render the same semantic selector independently.

Runtime hooks watch text/attributed-text assignment, label attachment and cell
reuse. A single coalesced update after configuration handles text assigned before
its row model. Changing row context stops the previous override; removing an
override restores the latest app-supplied value, including nil and attributed
text. Uniform attributed formatting is preserved. Mixed attribute runs are left
unchanged and the explorer explains that they need a component adapter.

Discovery walks happen when a rule is introduced, a remote manifest is adopted,
or an editor explicitly inspects a screen. Ordinary updates revisit weakly tracked
candidates. There is no frame/layout hook, repeating timer, or code injected into
host controllers. Labels inside UIKit controls, text inputs, tab bars and Ripul's
own overlay are excluded so their dedicated adapters retain ownership.
