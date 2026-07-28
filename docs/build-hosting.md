# Build hosting

Ripul hosts OTA builds for apps built on this SDK. Publish an IPA with a token,
render one SwiftUI view, and you have an in-app build list with history, release
notes, and install — no bucket, no worker, no install page, no Cloudflare
account of your own.

Using the SDK already requires a Ripul account, so this comes with it.

## What it replaces

Both first-party apps had independently built the same apparatus:

| | Before | Now |
|---|---|---|
| **ripul-native-app** | One "Install Latest Build" button → a static `manifest.plist`. No history, no notes, no way to know if you were already current. Every install a blind overwrite. | `RipulBuildsScreen` |
| **WAC** | R2 bucket + worker + hand-curated `install.html` + a 130-line Python script doing regex surgery on that HTML to insert build cards. Safari-only, nothing in-app. | `RipulBuildsScreen` |

WAC's `ota_page.py` existed *only* because there was no machine-readable feed —
the HTML page was the database. With a feed, the renderer is a view.

## Consuming the feed

```swift
NavigationLink("Builds") {
    RipulBuildsScreen(source: .ripulHosted(app: "your-app-slug"))
}
```

That's the whole adoption cost. Self-hosting the feed instead:

```swift
RipulBuildsScreen(source: .staticURL(URL(string: "https://…/builds.json")!))
```

A static feed is sent unauthenticated, so whatever serves it owns its own access
control.

To check status without showing the screen — a badge, a banner, a boot log:

```swift
let store = RipulBuildFeedStore(source: .ripulHosted(app: "your-app-slug"))
await store.refresh()
switch store.status {
case .updateAvailable(let build): // build.build, build.notes, build.installURL
case .upToDate, .unknown: break
}
```

`RipulBuildFeedStore` is a **leaf** `ObservableObject`. Keep it that way — a
`@Published` flip on an object the agent web view also observes re-renders
`AgentView` and stalls the WKWebView mid-scroll.

## Publishing

```bash
curl -X POST https://llm-proxy.ripul.io/v1/builds \
  -H "Authorization: Bearer $RIPUL_BUILD_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  -H "X-Ripul-Build-Metadata: {\"app\":\"your-app\",\"channel\":\"prod\",\"channelTitle\":\"Your App\",\"bundleId\":\"com.you.app\",\"build\":\"202607281530\",\"version\":\"1.0.0\",\"notes\":\"what changed\"}" \
  --data-binary @YourApp.ipa
```

`ripul-native-app/scripts/ship-ota.sh` has a worked example (`publish_to_feed`).

The body is the raw IPA, **not** multipart: parsing multipart in a Worker means
`formData()`, which buffers the whole body, and a ~98 MB IPA against the 128 MB
memory ceiling is an OOM. Streaming keeps memory flat.

Set `notes`. It is the only per-build description anyone installing ever sees.

### Channels

A channel is a named distribution track — Ripul's variants (`main`, `alice`) and
WAC's flavours (`prod`, `beta`, `dev`) are the same concept. Channels are created
implicitly by publishing to them.

`bundleId` is per build and load-bearing: the SDK compares it against
`Bundle.main.bundleIdentifier` to tell the user whether installing **replaces the
app they're using** or **adds a second icon**. Same bundle id means iOS
overwrites in place and terminates the running app to do it.

### Build numbers

`build` is `CFBundleVersion` and should be `YYYYMMDDHHmm`. The SDK compares build
numbers **numerically or not at all** — an unstamped build (`"1"`) reports
`.unknown` rather than being ranked by string order. Publishing the same build
number twice to one channel is a 409, not an append.

## Why install URLs expire

iOS does not download an OTA build through your app. Tapping an `itms-services://`
link hands the manifest URL to the system install daemon, which fetches the
manifest **and** the IPA itself — with no `Authorization` header, no cookies, and
no way to attach either. The usual bearer-token gate is structurally unavailable
on exactly the two URLs that matter.

So the artifact URLs are short-lived HMAC capability URLs, minted by the
authenticated feed endpoint. Consequences worth knowing:

- **The feed is the only place entitlement can be enforced.** Anything not gated
  there is not gated.
- **Install URLs go stale.** `RipulBuild.installURLIsLive` reports it; refreshing
  the feed mints new ones. An expired artifact request returns `410`, distinct
  from `403` for a bad signature, so the SDK can tell "refresh me" from "denied".
- **Don't persist an install URL.** Persist the build id and re-fetch.

## What hosting does not do

It removes the distribution plumbing. It does **not** remove Apple's gate: these
are development-signed builds, so the installing device must be registered on the
developer account, and the user may still have to trust the developer in
Settings → General → VPN & Device Management. Ripul gates *access* to a build;
Apple still decides which devices can run it.

## No install progress

There is deliberately no "installing…" state. iOS gives no completion callback,
and a same-bundle-id install terminates the app — so any in-memory flag dies
exactly when the install is working. Status is re-derived on next launch by
comparing `CFBundleVersion` against the feed. This is the binary-side counterpart
to the web app's `LIVE ✓ / STALE ✗` check.

## Registering an app

Currently a manual insert (there is no self-serve registration endpoint yet):

```sql
INSERT INTO build_apps (id, organization_id, title, publish_token_hash)
VALUES ('your-app', 'default', 'Your App', '<sha256 of the raw token>');
```

The raw token is shown once and only ever presented by the build machine.
Rotating it is an `UPDATE`; revoking it is a `DELETE`. `ship-ota.sh` reads it
from `RIPUL_BUILD_TOKEN` or `~/.ripul/build-token`.

A self-serve registration endpoint is the obvious next step if this becomes a
product surface rather than an internal one.
