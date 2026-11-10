# Sharing a device with someone else's chat

A person using an app built with the SDK can let the agent in another
person's Ripul chat read the app on their phone: a designer's unpublished
theme draft, say, read by a developer's agent. Nothing is shared until they
say so, only tools that read are shared, and it stops when they press Stop,
when they close the app, or after an hour.

Built 10 November 2026. The whole flow, the server's rules and the tests are
in `chrome-extension/docs/architecture/memberDevices.md`.

## What the app does: say which tools only read

A tool is shared only when it says it changes nothing:

```swift
struct ThemeServerTool: NativeTool {
    let name = "theme_server"
    let access: NativeToolAccess = .reads      // the app's own data
    …
}

public struct InspectScreenTool: NativeTool {
    public let access: NativeToolAccess = .readsScreen   // what is on screen
    …
}
```

- `.changes` is the default. A tool that says nothing is never shared.
- `.reads`: reads the app's own data and changes nothing, not even a local
  draft, a setting or a cache.
- `.readsScreen`: reads what is on screen. Shared only when the person also
  chose to share their screen.

One action that changes anything makes the whole tool `.changes`. Split a tool
whose actions mix reading and changing: wac's `theme_server` became
`theme_server` (status, diff, local_diff) and `theme_server_edit` (the actions
that delete the phone's draft or publish).

The SDK's own tools that read the screen say so: `inspect_screen`,
`screen_frame`, `screen_audit`, `wait_for_element`. So do `get_theme_style`
and `list_theme_scopes`. Console and network logs do not, because they can
carry credentials.

On Android the same field is `NativeTool.access`, with `NativeToolAccess.READS`
and `READS_SCREEN`.

## What the person sees

- **A card in the chat**, put there when the chat owner's agent asks for their
  device: share the app's tools that read, those and the screen, or not now.
  The app it is answered in is the one shared, so the card says to answer it
  in that app. In an app without what the agent asked for, answering is
  refused.
- **A pill at the top of the screen** while it is shared: "“Wac theme” can read
  this app", with Stop. It is Live View's pill (`LiveStreamIndicator`) with its
  own words, shrinks to a "Shared" mark after a few seconds and opens again
  each time the chat reads something. `DeviceSharingIndicator.swift` shows it,
  from the page's `agent-framework:device:sharing` reports; Stop calls the
  page's `window.__ripulStopDeviceSharing()`.
- On Android, `AgentBridge.deviceShares` and `stopDeviceSharing()`, and
  `DeviceSharingBanner(bridge)` for the app to place at the top of its screens.

The page tells the app nothing else, and keeps the person's choice itself
(`relay/memberDevice.ts`). The page also learns the app's name at start
(`window.__ripulHostAppName`, from `CFBundleDisplayName`), so the chat sees
"wac on iPhone".

## Store builds

Sharing is public API only. What can be shared is what the build compiles in:
wac's developer tools, `theme_server` among them, are in developer builds
only. Customers of an App Store build are reached through support sessions
(`support-sessions.md`); reading tools over a support session are not built
yet.

## Limits

- The app must be open, and the chat connected: an iPhone app in the
  background answers nothing.
- One hour at a time. The person shares again for more.
- Only the chat owner's own turns can use it.
