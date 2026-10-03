# Support sessions

Lets your app's customer show the app to somebody helping them, and lets that person point at
things in it. The customer signs in to nothing and installs nothing. It uses public Apple API
only, so it is the same in a store build as in a development build.

## What happens

1. The customer chooses **Get Help** in your app. The app asks Ripul for a six-digit code and
   shows it.
2. The customer reads the code to the supporter (on the phone, in a chat).
3. The supporter opens Ripul on an iPhone or Mac, goes to **Devices ▸ Help a Customer**, and
   enters the code.
4. Your app tells the customer who that is ("Helen Helper would like to see Shop") and what
   they will be able to do. Nothing is shared until the customer taps **Allow**.
5. The supporter sees your app, and only your app. A finger on their picture draws a ring on
   the customer's screen: "tap here". They can't tap, type or change anything; the customer
   does that.
6. A pill at the top of the customer's screen says who is watching, with **Stop**, for as long
   as the session runs.

## Adding it

SwiftUI:

```swift
import RipulAgent

struct HelpScreen: View {
    @State private var gettingHelp = false

    var body: some View {
        Button("Get Help") { gettingHelp = true }
            .ripulSupportSheet(isPresented: $gettingHelp,
                               configuration: RipulSupportConfiguration(siteKey: "pk_live_…"))
    }
}
```

UIKit:

```swift
RipulSupport.shared.present(from: self, configuration: RipulSupportConfiguration(siteKey: "pk_live_…"))
```

`RipulSupportConfiguration` takes the same publishable site key as `AgentConfiguration`. If your
app sends its own `Origin` on Ripul calls, pass it as `origin:`; it must be one the site key
allows. To build your own screen instead of `RipulSupportView`, observe `RipulSupport.shared.phase`
and call `start`, `allow` and `stop`.

## Who can use a code

The creator of the site key, and its owners and admins. To anyone else a real code and a wrong
one get the same answer, so a code can't be guessed at or probed for. A code that nobody takes
is forgotten after ten minutes; a session ends an hour after it is taken, or when either side
stops.

## What is and isn't shared

- The app's own window, as the app draws it. Not the keyboard, not the status bar, not other
  apps, not the home screen. Leaving the app pauses the picture; coming back carries on.
- Secure text fields are drawn as dots, as on screen.
- Nothing the supporter sends reaches the app. Their pointing is drawn in a window of its own
  over the app. Ripul's server enforces this as well: it passes the picture one way and
  pointing the other, and drops everything else.
- The picture travels over TLS through a room on Ripul's servers. It is not stored. It is not
  yet encrypted end to end between the two devices.

If a different supporter takes the code part-way through, the picture stops and the customer is
asked again.

## Limits today

- About five pictures a second while the screen moves and two at rest, at one pixel a point
  (text is readable, not sharp). The app draws its own window on the main thread to make each
  picture, which costs about 35–60 ms each, so scrolling in your app is a little less smooth
  while a session runs.
- One supporter at a time.
- iPhone and iPad apps. A Mac Catalyst app has not been tried.

## How it works

Both ends connect out to a room on Ripul's servers (`SupportRoom`, a Durable Object named by
the code), so neither needs to be on the same network as the other. The room carries Live
View's own stream (`LiveStreamWire`), one frame a WebSocket message. In the SDK the session is
`RipulSupport` (`Sources/RipulAgent/Support/`), which hands the room's channel to
`LiveStreamHost` in its support mode. The supporter's side is `SupportViewer.swift` in the
Ripul app.

To test without a second signed-in device, `ripul-native-app/support-probe` is a Mac
command-line supporter, and the Ripul app takes `-ripul.support.siteKey <key>` (be the
customer) and `-ripul.support.claim <base64>` (be the supporter) in debug builds.
