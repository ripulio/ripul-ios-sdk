# Native chat windowing

Native Chat (beta) mounts only a band of rows around the viewport and stands in for the rest with fillers based on measured or estimated row heights. Geometry corrections preserve the reading position as estimates are replaced. This bounds the mounted SwiftUI graph in long chats; ledger updates still process the loaded rows. It has been on by default since `23ec68b23` (26 Oct 2026), on iOS and Mac Catalyst. Native macOS stays eager.

On iPhone and Catalyst the chat is now drawn by a UIKit list with one owner of its scroll offset (below, [The viewport contract](#the-viewport-contract-9-november-2026)). The band, fillers and coordinator described after it are the SwiftUI scroller's, kept behind `ripul.nativeChatPerf.ownedList` until the list is accepted.

## The viewport contract (9 November 2026)
Peter, 8 November 2026, on his Duo: a chat he opened "nods a few times" after it lands, with nothing new to see. Every fix since October had added a place that moved the scroll offset (the entry hold, the follow glide, the reading-row correction, the keyboard, band growth, stuck recovery, jumps, restoration), and SwiftUI's scroll view moved it too: the composer folding to its pill and back within 15 ms moved the content 89 pt and SwiftUI's offset 44 pt on Peter's iPhone 17 Pro Max. The plan, the evidence and the three-agent review are in `docs/plans/native-chat-viewport-owner.md`.

- **One owner.** `NativeChatViewport` (pure, `NativeChatViewportTests`) decides the offset. `NativeChatList` (`NativeChatListScroller`, a `UIScrollView` whose `layoutSubviews` we write, hosting each row's SwiftUI view in a `UIHostingController` that takes none of the window's safe area, `safeAreaRegions = []`: rows in `UIHostingConfiguration` content views, which cannot be told that, held their content at the top bar's edge as they passed under it, so messages seemed to stick there, on the open Duo in portrait even when told to ignore the safe area) measures the rows it mounts, lays every row out from the height ledger (`NativeChatWindowModel`), commits the layout to the owner and applies the offset it answers, and mounts what is within a screen of the visible area, all in one pass before anything is drawn.
- **Nothing else writes the offset.** UIKit's finger, coast, bounce and status-bar tap move it, and the owner hears of them (`noteManualOffset`). The follow glide is the list's own display link, stepping the owner's spring. Every write runs without an enclosing animation. Debug builds log any other move as `[ENTRYNOD] list moved (not ours)`.
- **The rules of a commit**, by what the reader is doing:
  - *entering* (a chat entered, appearing, or its first rows; 3 s or until a touch): the end, on every commit, with no glide;
  - *following*: the newest row present in both layouts keeps its place on screen, so content changing above it moves nothing; growth below it and a change of the clearance below the rows (keyboard, composer) become distance to glide, on a critically damped spring (16 rad/s; 30 while the clearance moves or the end comes up);
  - *reading* (a row shown or restored, or the place a coast came to rest away from the end): that row keeps its place on screen, or the nearest row that stayed if it went;
  - *manual* (under a finger or a coast): the first row on screen keeps its place.
- **A glide in flight keeps its distance and speed through history.** A layout committed twice moves nothing.
- **Rows are not held** for coasts, jumps or restorations. One hold is left, for a send: while following, a drop in the clearance (the keyboard going down, the composer shrinking as its text clears) holds new rows until 0.4 s after the last drop, so the sent message glides up once above the composer as it will rest.
- **A drop in the bottom clearance waits 60 ms** before the chat moves for it, and a rise in between cancels it, so the composer folding to its pill and unfolding within moments moves nothing (Peter's iPhone 17 Pro Max: 195 → 106 → 195 pt within 15 ms). A rise is taken at once: nothing may sit under a growing composer or keyboard. Three such folds over a chat at rest on the Duo simulator moved its last row 49.3 pt over 45 frames with the SwiftUI scroller, 15.7 pt over 33 with the list taking each drop at once (`-perfOff clearanceDropDelay`), and 0 with the wait.
- **A place to restore or a message to show** waits up to 2 s for its row to arrive.
- **Hosted rows take the chat's own environment values** (`openURL`, `screenIsShown`, the theme's version, tint and font, and a few more) and the system's (appearance, text size) through UIKit's traits. Not the whole environment: handed `EnvironmentValues` whole, a row also took the accessibility state SwiftUI keeps there, and VoiceOver found nothing inside a row until the next update.

Tested by `NativeChatViewportTests` (`swift test --filter NativeChatViewportTests`) and, on the Duo simulator, `testNativeChatHoldsStillWhileHistoryLandsAboveIt` (`chat-g`: ten 430 pt screenshot cards landing above a following chat at the times of Peter's log; the last row as drawn, every frame for seven seconds: 0.0 pt, 0 moves in 420 frames), `testNativeChatHoldsStillThroughAFoldUndone` (chat-c at rest, the composer's clearance driven as the tab shell drives it, folded and unfolded 15 ms later three times; with the SwiftUI scroller and with each drop taken at once as controls), `testNativeChatOpensEveryEnteredChatAtItsEnd`, `testNativeChatColdEntryHoldsStillWhileSliding` and `testSentMessageAndReplyGlideToTheEnd`. Any change to the native chat, the composer's clearance, the forwarder or the tool-image pipeline runs them.

**Scrolling.** `testNativeChatScrollHitchesAgainstTheOldScroller` flings chat-a (170 rows of text) toward older messages and back, six flings each way, recording every frame's gap (`HitchRecorder` in the harness: a hitch is a frame more than one and a half intervals after the last), and alternates the two scrollers in the same build. XCTest's own hitch metric gives no numbers on a simulator (only the coast's length: 2.43 s and 2.42 s). Duo simulator, 9 November 2026:

| Round | Scroller | Hitches | Time lost | Worst frame | Frames |
|---|---|---|---|---|---|
| 1 | SwiftUI scroller | 61 | 5,730 ms | 403 ms | 2,081 |
| 1 | owned list | 21 | 412 ms | 50 ms | 2,222 |
| 2 | SwiftUI scroller | 75 | 5,825 ms | 470 ms | 2,095 |
| 2 | owned list | 17 | 331 ms | 50 ms | 2,217 |

A simulator's frames are not a phone's; the phone's numbers are still to measure. A streaming reply hosts its own row again and no other (`HostKey`): every mounted row is hosted again only when what they share changes (text size, thinking, gutters, theme, screen shown).

Debug builds log a move by anyone else (`moved (not ours)`) rather than assert on it: they are the builds on Peter's phones.

## Why
Profiling on the iPhone Duo simulator (`/tmp/scroll-council/claude/profile-step1.md`) showed that once our own scroll code was cheap, SwiftUI updated and rendered the whole mounted graph every scroll frame. So the cost followed the number of mounted rows: at ~590 rows, 90% of drag frames were late, and each older page froze the main thread for 0.4-1.5 s. Removing the row markers, the per-row GeometryReaders, text selection, or SwiftUI's ScrollView itself changed nothing. Only mounting fewer rows did.

## How it works
- **Structure** (`NativeChatView.scroller`): the outer `VStack(spacing: 10)` holds one row section, `VStack(spacing: 0) { top filler; VStack(spacing: 10) { mounted rows }; bottom filler }`. With prefix sums `P` over layout slots and a spacing of 10, `top = min(total, P[a])`. If the band contains a layout slot, `bottom = max(0, total − (P[b] − 10))`; otherwise `bottom = total − top`. Confirmed no-slot rows contribute neither height nor spacing. The geometry is identical to the eager stack whenever the heights are exact.
- **Model** (`NativeChatWindowModel.swift`, pure, unit tested in `NativeChatWindowModelTests`):
  - row descriptors with equality-based revisions (`NativeChatRowRevisionTracker`), folded together with the row-state registry's revisions;
  - a height ledger keyed by row id + revision + `LayoutKey` (pixel-snapped width, scale, Dynamic Type, how thinking is shown), with estimated or mounted confidence;
  - estimates from the row's own last measured height, else the median for its kind;
  - band plans: 1 viewport of overscan each side, 2 in the travel direction when fast, a 0.5-viewport trigger, chunks of 4, soft cap 32 and hard cap 48, visible rows always mounted;
  - a structure generation for hysteresis, and no-slot rows.
- **Coordinator** (`NativeChatScrollCoordinator`):
  - Locates viewport rows by binary search and plans the band from the scroll handler and after every offset the coordinator itself writes (follow, scroll to bottom, restoration, navigation). Checks after coordinator writes are coalesced onto the main queue to avoid reentrant geometry publication.
  - Publishes through `NativeChatWindowBand` only when the mounted rows or fillers change.
  - Measures mounted rows as one batch per coherent pass.
- **No nod:**
  - Before a band is published, the reading row's real on-screen position is captured. Once the matching pass has laid out (serial plus marker agreement), the offset is corrected from the live offset.
  - While tracking or decelerating the correction writes `sv.contentOffset = p`, the property, which keeps a fling going (`setContentOffset(_:animated:)` stops it; measured with a test app on a simulator).
  - Layout-key changes (Duo fold, rotation, Catalyst resize, Dynamic Type, the Thinking setting) keep the current band, correct against the pinned reading row's real marker, then update the ledger. With thinking set to None, thinking rows draw nothing and become rows without a slot.
  - Pending geometry/anchor waiters recover after 30 waiter ticks or 0.5 s (`stuck=`): the coordinator abandons the stale baseline and re-plans from the current viewport. This prioritizes restoring visible content over retaining an unresolvable anchor.
- **Page landing:** older rows enter the top filler as estimates, unmounted, with an offset correction of the same estimated amount. They are measured when the band reaches them.
- **Navigation and restoration:** a target that isn't mounted gets a band centred on it and an initial offset from the ledger. Once its marker is mounted, navigation centres and highlights it; restoration places it at its saved reading offset. Restoration is only for turning Native Chat on from the web chat; a chat that is entered opens at its end (below).

## Entering a chat
Every chat that is entered opens at its end (Peter, 27 Oct 2026: "sometimes blank until I scroll and not at the end"). Entering is `AgentBridge.focusSession`, which every way of opening a chat goes through and which calls `NativeChatMessageStore.enterChat()` (the `.enter` scroll command), the same chat shown again included; and, in the view, a chat switch, a chat's first rows, and the view appearing. All of them call `NativeChatScrollCoordinator.pinEntryToEnd()`.
- The place the page saved for a chat (the `scrollPosition` of a backfill) is not restored on a switch. Only the web/native toggle restores one, and `enterChat()` drops a toggle still waiting: the app turns Native Chat on from its saved setting at launch, which marked a toggle, so the first chat opened after a launch restored its saved place.
- For 3 s after (`entryPinSeconds`), while estimates become measured rows and a catch-up rewrites the tail, each content-height change follows to the end at once, without waiting for a pending layout pass to agree (`requestFollow` skips its `awaitingGeometry` gate). The end is the reader's place, so nothing above it needs correcting first. The first touch ends it.
- A layout wait that gives up (`stuck=`) no longer leaves the view where it was: following, it goes to the end; reading, an offset past a shortened end is brought back. On Peter's phone each entry logged `stuck=serial` or `stuck=marker`, and a recovery used to end a restoration with following off, so the chat stayed partway up, or past the end of a shorter chat (blank until a touch bounced it back).
- A switch sets following before the window plans the new chat (`resetForChatSwitch`, unless the web chat's place is waiting), and `handleChatIdChanged` hands the window the new rows before it plans, so it plans the new chat's end, never the last chat's tail or reading position.
- **The nod on a cold entry (8 November 2026).** On Peter's open Duo, a chat not yet loaded on the phone gets its history in the same update as the slide that brings it in. Traced frame by frame, its rows started each slide about 70 pt too high and came down on the slide's own curve (70, 71 and 76 pt on three entries; warm re-entries 0; the same with Smooth follow off). The coordinator's offset writes now run without inheriting an enclosing animation (`UIView.performWithoutAnimation` in `writeContentOffsetY`). Whether that removes it on the phone is not yet measured: the harness's `chat-f` (72 rows, cold, rows landing with the slide) does not reproduce it, 0 pt with the change and without (`testNativeChatColdEntryHoldsStillWhileSliding`), so the cause may lie in the app's own chrome. `[ENTRYNOD]` (below) logs what moves a chat during an entry.
- Tested by `testNativeChatOpensEveryEnteredChatAtItsEnd` (`--native-chat-entry-ui-tests`, `NativeChatEntryHarnessSurface` in `PreviewTestHost.swift`): the chat column slides in over a list as on the iPhone, the switch lands while it is off screen with a saved place, a cold chat comes empty and then with its rows (as the page's forwarder sends a chat still loading), catch-ups rewrite the tail during and after the slide, and it checks the end and the last message on screen for eight entries. Against the code before this change (27 Oct 2026, the same test on a pre-fix copy of the SDK) three failed: a cold chat first after launch sat 11,367 pt above its end, the same chat entered again after reading up 3,285 pt, and a cold chat after reading another partway opened at its first message (29,916 pt). With it all eight pass.
- **Row-local state** (`NativeChatRowState.swift`): disclosures, tool-strip collapse, reveal counts, tabs and unsent answers live in a per-chat registry keyed by `(rowId, componentId)`, so a row that unmounts and remounts keeps them while its entries remain cached. Scalar state, tool-strip stores/subscriptions, task-run stores and revision metadata each have an LRU bound (4096 entries by default), and a genuine chat switch clears the registry. A height-affecting change or state/store eviction bumps the row's revision; revision metadata eviction retains a monotonic revision floor. Evicted user controls return to their defaults on remount, with the previous measured height treated as an estimate.

## Holding the tail while reading
While an agent works, rows at the tail change every second or two, and each publication walks every row (`updateWindowRows`: revisions, descriptors, prefix sums, lookups) plus SwiftUI's row diff, on the main thread. That cost grows with the chat: about 1.4 ms at 90 rows and 4 ms at 174 rows on the Mac simulator, so roughly 11 ms per update at 500 rows, more than a 120 Hz frame. Scrolling in the middle of a streaming chat paid it mid-drag for rows nobody could see.

So while the reader is away from the tail (not following), a store change that touches only rows below the screen is held (`holdsTailChange`). The store keeps the data; only the published rows wait. Held rows publish:
- on return to the bottom (any re-pin, Latest, the scroll-to-bottom button);
- when a scroll comes to rest with a held row on screen;
- before a jump (scroll commands, row actions), with the window updated at once so the target is found;
- with the next change that touches a row on screen, which publishes everything.

A change that appends the reader's own message is never held, so sending a message while scrolled up still shows it. Measured on the Duo with a Haiku agent streaming a step every ~2 s, five slow drags mid-chat per arm: hold off, 23 and 15 publications (about 34 ms of main thread) and 12 and 9 band rebuilds; hold on, none of either, 20 updates held. Drift stayed 0.

## The steady band (27 Oct 2026)
Peter found native scrolling choppy once an older page had loaded, and smooth on entry. A chat opens with fewer than 80 rows, every row mounted; the first older page takes it past 80 and switches the band on. The band then moved during every fling, mounting and dropping rows mid-coast, and each band change costs about a frame however many rows it moves. Measured on the Duo with the clean method (below), six flings toward older rows at 87-142 rows lost 726-798 ms with 17-22 hitches. The same chat with every row mounted lost 50 ms with 3 hitches.

Mounting every row is no answer either. Streaming took the main thread to 100% with 83 rows mounted, against 75% with the band. A page landing stalled 125-242 ms against 29-91 ms. Past about 150 rows mounted, scrolling itself starts to hitch again. So the band stays and holds still (`NativeChatPerformance.steadyBand`, on by default):
- **During a fling** (tracking, dragging, decelerating, or an animated scroll such as a status-bar tap): the band keeps its rows. Nothing changes until the screen comes within half a screen of the edge it travels toward. That edge then moves two screens ahead in one change of at most 16 rows (`NativeChatWindowModel.motionPlan`). Past the cap, only as many of the farthest rows behind go as were added: they are measured, so dropping them moves nothing. A pass that follows rows landing or leaving keeps the same rows mounted, found by id, and nothing grows or goes. Direction comes from the offset's own motion, which a coast keeps.
- **At rest**: the band grows toward a rest band a few rows at a time, nearest the screen first (`restPlan`, `growthStep`), so the next fling finds its rows mounted and measured and their corrections land while nothing moves. Each step waits until the last one is laid out (its serial committed, no anchor or geometry pending). Steps are capped at 48 per rest, with about a second of waiting, and a touch stops them.
- **Quiet or active**: a chat with no row change for 3 s and no turn running is quiet. It grows toward every loaded row, up to 160, six rows a step, at its tail too. While rows change or a turn runs, the rest band is 3 screens ahead and 2 behind, 64 rows at most, and growth waits for 0.5 s without a change. A grown band shrinks 16 rows a step, including while following a chat whose rows change, so a sent message never unmounts a hundred rows in one frame. After growth above the screen, the follow settles to the tail at once.

Results on the Duo, six flings toward older rows, steady band against the old band in the same build:

| Chat | Flings | Steady | Old |
|---|---|---|---|
| Idle, ~88 rows | resting (3.5 s apart) | 5 hitches, 92 ms lost, worst 45 ms | 8 hitches, 450 ms, worst 159 ms |
| Idle, ~88 rows | fast (1.2 s apart) | 11 hitches, 337 ms, worst 72 ms | 11 hitches, 511 ms, worst 147 ms |
| Grown to every row, ~144 rows | resting | 1-6 hitches, 9-79 ms (3 of 4 runs; one run had a single 256 ms stall) | 20-24 hitches, 727-1156 ms |

While scrolling a grown band, the app's processor time is higher (35-47% of a core against 14-22%). A stream shrinks the band first, so streaming costs what it did.

**A turn of the phone (7 Nov 2026).** Every mounted row is laid out again at a new width, and a chat of 80 rows or fewer normally has all of them mounted. On the open Duo a turn of the Agents screen cost 0.92 to 0.95 s of main thread, against 0.25 to 0.3 s on Home.

- `beginSizeTransition` runs as UIKit announces the new size (`SizeTransitionReader`), before the turn is laid out. It cuts the band to the rows on screen and a screen either side, at most 24 rows.
- After the turn (0.6 s), the band grows back at rest, six rows a step, as a long chat's does, until every row is mounted again. While it is growing, the 80-row rule doesn't apply (`windowTurnBand`).
- This only happens at the tail, where the chat stays pinned to its end. Reading further back, a turn keeps every row, as before.
- Each cut shows in a trace as the mark `turn: chat band a..b of n`.

## Following the end (5 Nov 2026)
Peter: a sent message "is never smooth, it's always a jump", and replies sometimes "scroll up in blocks". `NativeChatFollowUITests` (`NativeChatFollowHarness`) opens a 150-row chat at its end, leaves it quiet for 6 s, raises a keyboard 336 pt tall (`keyboardWillShow`, as tapping the composer does) and types four lines into the real composer (`pendingInputText`), sends (the keyboard going down, as a tapped Send lowers it; the message 80 ms later; the composer clearing 150 ms in, as the page's acceptance does), and streams a reply a sentence every 140 ms. It watches, every frame, where the chat is drawn (the scroll view's presentation), where the history's last row is drawn (its row marker's presentation: a move of more than 24 pt in a frame is a jump someone sees), and every offset write that went to the end at once (`NativeChatScrollCoordinator.debugInstantFollows`, Debug builds). It runs with Smooth follow off as the control, then on.

| iPhone 17 simulator, 5 Nov 2026 | Smooth follow off | On |
|---|---|---|
| Keyboard comes up: biggest move of the last row in a frame | 66-368 pt, at once | 27-65 pt (a glide's fastest frame at 60 Hz) |
| Send: the chat first moves | after 671-728 ms (one line) | at once (66 ms) |
| Send of four lines: the message shows | 150-216 ms | 669 ms, once the composer has collapsed (before: with the reply's first row, then under the collapsing composer) |
| Send: biggest move of the last row in a frame | 113-665 pt | 109-113 pt |
| Reply streaming: frames moving a row more than 24 pt | 0-3 | 0 |
| Offset writes that went to the end at once | `bandChange` 302, `forced` 307, `bandChange` 84 | none |

The causes, each fixed behind Smooth follow:
- **The follow waited out every layout pass.** The follow (`requestFollow`, gated on `awaitingGeometry`) waited for each band publication to land, and a band grown while the chat sat quiet shrinks in steps as soon as rows change: in the first harness run the chat did not move for 0.6 s after the send, with the message 69 pt below the end. It now glides through a pending pass (`followGlidesThroughLayout`): windowed corrections land on the live offset, so they move with a glide. A content-size change that moves the end down starts the glide at once, without planning the band again mid-layout (`checkingBand: false`). It still waits when a jump, a restoration, a resize's anchor or an instant follow depend on that pass.
- **A band step made the next follows instant.** Within 0.6 s of any band step (`windowLastGrowthPublication`) a follow went to the end at once, and a quiet chat grows its band just when the keyboard comes up or a message is sent. With Smooth follow on, a follow glides after a band step too.
- **The end coming up was met at once.** It now glides down, on a stiffer spring.
- **The glide surged.** The old step moved a fixed share of the remaining distance each frame (an 85 ms time constant), so it set off at full speed every time the end moved. It is now a critically damped spring (`followSpring`, 16 rad/s) whose speed carries over as the end moves: a sent message eases up and settles in about a third of a second, and each new line draws the glide on. For 0.45 s after the bottom inset changes (`followTheKeyboard`), and whenever the end is above the chat, it uses `followSpringDown` (30 rad/s, about 0.2 s), to keep up with the keyboard.
- **Growth steps landed under the keyboard's animated inset.** The keyboard changes the chat's bottom inset inside `withAnimation`, and SwiftUI lays the whole chat out again every frame of it. A growth step (rows estimated at about 110 pt that measure about 200, so corrections of 494 and 609 pt) published then had its correction wait until the animation stopped: the rows pushed the chat down 535-665 pt for half a second as a message was sent. Growth now waits until 0.6 s after an inset change. (The corrections themselves land in the same frame and are not seen.)
- **The sent message cut the keyboard's animation short.** It arrives about 80 ms into the keyboard's 0.45 s, and a band publication runs without animation, which ended the inset's animation at once: SwiftUI clamped the offset to the new end and the chat dropped the rest of the keyboard's height in one frame. New rows now wait while the keyboard goes down (0.4 s, `holdRowsUntil` in `shouldHoldRowPublication`), then glide in.
- **A message of more than one line stayed held until the reply came.** It drops the inset twice, the keyboard and then the composer shrinking as its text clears, and the second drop waits again. The first wait found the second running and gave up (Peter: "anything over 1 line just appears"); it now waits again (`flushHeldRowsOnceKeyboardIsDown`).
- **The message was published under the collapsing composer.** The wait that follows a fling (`stepWaitForDecelerationEnd`) also runs for a band's layout passes, and with nothing decelerating it published held rows at once: a message of several lines showed 216 ms after Send, while the composer was still collapsing over it, and its glide went unseen (Peter: "is it because the chat composer extended over the glide"). It leaves rows held while the inset drops; the message now shows at about 670 ms, once the composer is down, and glides up. The composer's own collapse moves the chat on a curve too (`AgentView.updateComposerHeight`, easeOut 0.25 s): set plainly, its content shrank in one step and SwiftUI moved a chat at its end down by the whole drop at once.
- **Growth ran while someone typed.** A growth step landing as a Send lowered the keyboard pushed the chat down 665 pt. The coordinator now hears the keyboard from the system itself (`watchTheKeyboard`, a turn before the inset follows it through `KeyboardObserver` and SwiftUI): the band does not grow while the keyboard is up, and a keyboard going down opens the follow window and the row hold at once. The window also lasts while the content is still changing with an animated inset.
- **A correction was cut at the end.** A pinned anchor's correction landing in the same pass as the end coming up was cut at the new end, which dropped the chat by the difference. Following, it is no longer cut; the glide brings the chat down.
- **A stuck wait's recovery went to the end at once.** Following, it now glides, unless the chat is held at its end on entry.

What is left is the keyboard's own curve. `KeyboardObserver.hideAnimation` (a timing curve of 0.05, 0.7, 0.1, 1.0 over 0.45 s) covers about half its distance in its first frame, so a following chat drops about 165 pt in the first frame of a keyboard going down, at 60 Hz. Whether that should match the system keyboard's own curve more closely is a judgement to make on a phone.

Tried and dropped: anchoring the first row on screen instead of the last while following (so a row above the last one growing would glide rather than move everything above the last row at once) broke `testNativeChatOpensEveryEnteredChatAtItsEnd`, three of eight entries opening 1391 pt above their end; and a bottom inset that changes in one step (no animation) let SwiftUI clamp the offset at once when the keyboard went down, a 233 pt jump.

## Switches
- `ripul.nativeChatPerf.ownedList`: absent means on, on iPhone and Catalyst (Settings > Debug > Native Chat Performance > Owned chat list, or `ripul://perf?nativeChat.ownedList=off`). Off brings back the SwiftUI scroller with its band and coordinator (everything below this line), for an A/B. It is read when the chat view is made: open the chat again after changing it. Debug builds log a `[LISTPERF] owned …` or `[LISTPERF] old …` line for every gesture on either: frames, dropped frames (`hitches`, more than one and a half intervals), `lostMs`, `worstMs`, the display rate, and for the owned list its layout passes, mounts, unmounts, measures, re-hosted rows and their times.
- `ripul.nativeChatPerf.smoothFollow`: absent means on (Settings > Debug > Native Chat Performance > Smooth follow). Off brings back the follow before 5 November 2026: the old step, waiting for layout, and going to the end at once after a band step or when the end comes up. It is read on each use.
- `ripul.nativeChatPerf.steadyBand`: absent means on (Settings > Debug > Native Chat Performance > Steady band in long chats, or `ripul://perf?nativeChat.steadyBand=off`). Off brings back the band that moves with the scroll. It is read on each band check.
- `ripul.nativeChat.windowing`: absent means on. It is a kill switch: `defaults write io.ripul.app ripul.nativeChat.windowing -bool NO`, or on a simulator, `xcrun simctl spawn <udid> defaults write io.ripul.app ripul.nativeChat.windowing -bool NO`, brings back the eager stack. The setting is read when the chat is shown; reopen the chat after changing it. Chats of 80 rows or fewer mount every row either way.
- `ripul.nativeChat.holdTailWhileAway`: absent means on; `-bool NO` publishes every change at once again. It is read live.
- `-perfOff unanimatedOffsets` (Debug launch argument): the coordinator's offset writes take whatever animation they are made in again, as before 8 November 2026. For an A/B of the entry nod.
- `-perfOff rowController` (Debug launch argument): the owned list's rows in `UIHostingConfiguration` content views told to ignore the safe area at top and bottom, as from 9 November 2026 until they were seen to stick on the open Duo, instead of hosting controllers. For an A/B of the two hostings (`testFollowRowHostingControl`, `testNativeChatScrollHitchesRowHosting`).

## Measuring (DEBUG builds, which phone and Catalyst builds are)
Launch with `-perfOn scrollPerf` (since 26 October 2026: its 120 Hz display link ran on every streaming change in everyone's DEBUG build). Each gesture or settle then logs a `[SCROLLPERF]` line (read it with `device_console_logs`, query `SCROLLPERF`). The fields:

| Field | What it shows |
|---|---|
| `frames` / `hitches` | display-link frames, and how many were later than 1.5× the target |
| `lost` / `worst` | time past each late frame's deadline, summed, and the longest gap |
| `grow` | steady band growth steps since the last line (at rest, so not counted in `moves`) |
| `drift` | max/over/sampled: the reading row's on-screen move not explained by user scrolling or our own corrections, i.e. the nod |
| `mounted`, `band` | how many rows are mounted, and which |
| `moves` | band moves |
| `corr` | compensations applied |
| `wait` | passes waited on |
| `nav` | staged jumps |
| `layoutKeyChange` | layout key changes |
| `stuck` | waiters that hit the liveness limit |
| `root` | content size |
| `rowsPub` | row publications (`updateWindowRows`) and their main-thread time |
| `held` | store changes held below the screen |

For 3 s after each entry pins a chat to its end, `[ENTRYNOD] +<ms>` lines log every offset write (`write a->b`), every move of the offset by anyone else (`moved a->b (not ours)`), and every change of the content's size, the scroll view's bounds and the chat's top and bottom insets, each with the scroll view's geometry and the duration of the animation it was made in (`anim`). Debug builds, no switch needed: read them with `device_console_logs`, query `ENTRYNOD`. The owned list logs its own for 4 s after each entry, as `[ENTRYNOD] list +<ms>`: `enter`, every commit that moved the offset (`commit <intent> a->b end=…`), clearance changes, placements, and at any time a move by anyone else (`moved (not ours)`).

Page back with `window.postMessage({type:'agent-framework:nativeChat:action', op:'loadMore'}, '*')` via `device_evaluate`. A page landing (five or more rows more) logs its own `[SCROLLPERF] landing rows=a->b firstFrame=… worst=… lost=… frames=… mounted=…` line 0.6 s later, at rest or not.

**The clean method.** Fling with the plain `touch` command and read only these lines. A `layer_animations` trace walks the whole view tree every frame and looks up accessibility ids: on 27 Oct 2026 that was half the main thread's busy time during a fling, and it grows with mounted rows, so its hitch counts are not native chat's. `sample` at its default 1 ms interval also distorts the app's timing. Runs on the shared Mac vary from run to run (215 against 539 ms for one configuration), so compare each change against its switch turned off, in the same build, alternated. Test the quiet behaviour in a chat with no turn running: a chat whose agent is working, such as the one doing the test, stays active.

## Acceptance (Duo simulator, Debug, ~450-590 rows; control = eager)

| Test | Eager control | Windowed |
|---|---|---|
| Drags | 121 of 134 frames late (90%) | 1-3% late |
| Flicks across estimated rows | — | 1-3% late |
| Page landing stall | 400-950 ms | none ≥250 ms |
| Drift | 0.0 pt | 0.0 pt |

Drift was measured across drags, flicks, idle landings, unfold and fold (with rotation), a far jump to the first user message, scroll to bottom / Latest, keyboard up and down, auto-load at the top, and row-state remounts. The full log is in `/tmp/scroll-council/step2/LOG.md`.

## Known limits
- Artefact web views are still cached without eviction, so unmounting a row does not free its WKWebView.
- `cachedImage(for:)` still decodes base64 attachment payloads synchronously on main.
- A chat whose rows are all very tall mounts few rows. Mount cost per band move depends on the heaviest rows (big code blocks, tool groups).
- The steady band grows toward every row only in a quiet chat. Scrolling back through a chat whose agent is working keeps the compact band, which still changes mid-fling once a fling runs past it. A chat of more than 160 rows mounts 160 at most.
