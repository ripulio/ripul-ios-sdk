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
notifications. This does not add automatic text replacement to unbound elements.
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
registered theme kinds. It lists every registered scope, including elements not
currently mounted. Search finds names, paths, IDs and current text; **Text elements
only** filters the list to kinds with free-text knobs. Selecting a row opens native
controls backed by the same engine mutations as View Explorer and the in-app editor.
This lists theme-bound text/settings; it does not invent bindings for hard-coded
labels or user-entered record data.

**Theme document** is a native text editor for the complete JSON. **Apply to app**
validates it through the host's existing full-document callback before previewing.
Both routes feed one local draft. Drafts, including temporarily invalid JSON, survive
closing the editor or a failed publish, isolated per app and theme URL. Foreground
refresh is paused while this editor is open so it cannot replace an in-progress
preview. Closing resumes ordinary server refresh; the unpublished draft remains
available when the editor is reopened.

**Review & Publish** shows changed values, additions and removals. Publishing uses
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
