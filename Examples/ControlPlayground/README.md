# Playground

The CMS site `control-playground` (`cms_r55ri3v0pk02`) as an iPhone app. Each page shows the same made-up data through many configurations of one family of controls (calendar strip, lists, cards, record forms, sidebar pieces, action button, page levers, timeline, KPIs). `CmsAppView` draws the site's tab bar as iOS's own and every page natively.

Nobody signs in. The app reads the site's public data with its publishable key:

- `CmsClientConfig(visitorSendsSiteKey: true)` sends the key as `X-Site-Key`, with `Config.origin` as the `Origin`, in place of the site-key session token. The worker runs queries, views and mutations for that header only when they are marked `exposedToSiteKey`, with row rules held to the site key. It refuses a session token on those routes.
- None of the playground's mutations are exposed to the site key, so forms open and fill but don't save.
- `Config.origin` is `https://playground.ripul.io`, the site's own address, on the key's (`sk_n3hk6kpwggfq`) `customDomains` and `allowedOrigins`.

## Build

```bash
cd ripul-ios-sdk/Examples/ControlPlayground
xcodegen generate
# Simulator: build outside the repo (no DerivedData folder is sanctioned for this app).
xcodebuild build -project ControlPlayground.xcodeproj -scheme ControlPlayground \
  -destination 'platform=iOS Simulator,id=<borrowed udid>' -derivedDataPath /tmp/<yours>
# Device (Debug, team C7AA358R56, automatic signing):
xcodebuild build -project ControlPlayground.xcodeproj -scheme ControlPlayground \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/<yours> -allowProvisioningUpdates
```

Bundle id `io.ripul.playground`, display name Playground. A simulator Debug build starts the SDK's simulator tools, so an agent's chat can drive it (`device_connect_simulator_app`).
