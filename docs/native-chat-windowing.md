# Native chat windowing

Native Chat (beta) mounts only a band of rows around the viewport and stands in for the rest with fillers based on measured or estimated row heights. Geometry corrections preserve the reading position as estimates are replaced. This bounds the mounted SwiftUI graph in long chats; ledger updates still process the loaded rows. It has been on by default since `23ec68b23` (26 Oct 2026), on iOS and Mac Catalyst. Native macOS stays eager.

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
- **Navigation and restoration:** a target that isn't mounted gets a band centred on it and an initial offset from the ledger. Once its marker is mounted, navigation centres and highlights it; restoration places it at its saved reading offset.
- **Row-local state** (`NativeChatRowState.swift`): disclosures, tool-strip collapse, reveal counts, tabs and unsent answers live in a per-chat registry keyed by `(rowId, componentId)`, so a row that unmounts and remounts keeps them while its entries remain cached. Scalar state, tool-strip stores/subscriptions, task-run stores and revision metadata each have an LRU bound (4096 entries by default), and a genuine chat switch clears the registry. A height-affecting change or state/store eviction bumps the row's revision; revision metadata eviction retains a monotonic revision floor. Evicted user controls return to their defaults on remount, with the previous measured height treated as an estimate.

## Holding the tail while reading
While an agent works, rows at the tail change every second or two, and each publication walks every row (`updateWindowRows`: revisions, descriptors, prefix sums, lookups) plus SwiftUI's row diff, on the main thread. That cost grows with the chat: about 1.4 ms at 90 rows and 4 ms at 174 rows on the Mac simulator, so roughly 11 ms per update at 500 rows, more than a 120 Hz frame. Scrolling in the middle of a streaming chat paid it mid-drag for rows nobody could see.

So while the reader is away from the tail (not following), a store change that touches only rows below the screen is held (`holdsTailChange`). The store keeps the data; only the published rows wait. Held rows publish:
- on return to the bottom (any re-pin, Latest, the scroll-to-bottom button);
- when a scroll comes to rest with a held row on screen;
- before a jump (scroll commands, row actions), with the window updated at once so the target is found;
- with the next change that touches a row on screen, which publishes everything.

A change that appends the reader's own message is never held, so sending a message while scrolled up still shows it. Measured on the Duo with a Haiku agent streaming a step every ~2 s, five slow drags mid-chat per arm: hold off, 23 and 15 publications (about 34 ms of main thread) and 12 and 9 band rebuilds; hold on, none of either, 20 updates held. Drift stayed 0.

## Switches
- `ripul.nativeChat.windowing`: absent means on. It is a kill switch: `defaults write io.ripul.app ripul.nativeChat.windowing -bool NO`, or on a simulator, `xcrun simctl spawn <udid> defaults write io.ripul.app ripul.nativeChat.windowing -bool NO`, brings back the eager stack. The setting is read when the chat is shown; reopen the chat after changing it. Chats of 80 rows or fewer mount every row either way.
- `ripul.nativeChat.holdTailWhileAway`: absent means on; `-bool NO` publishes every change at once again. It is read live.

## Measuring (DEBUG builds, which phone and Catalyst builds are)
Each gesture or settle logs a `[SCROLLPERF]` line (read it with `device_console_logs`, query `SCROLLPERF`). The fields:

| Field | What it shows |
|---|---|
| `frames` / `hitches` | display-link frames, and how many were later than 1.5× the target |
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

Page back with `window.postMessage({type:'agent-framework:nativeChat:action', op:'loadMore'}, '*')` via `device_evaluate`.

## Acceptance (Duo simulator, Debug, ~450-590 rows; control = eager)

| Test | Eager control | Windowed |
|---|---|---|
| Drags | 121 of 134 frames late (90%) | 1-3% late |
| Flicks across estimated rows | — | 1-3% late |
| Page landing stall | 400-950 ms | none ≥250 ms |
| Drift | 0.0 pt | 0.0 pt |

Drift was measured across drags, flicks, idle landings, unfold and fold (with rotation), a far jump to the first user message, scroll to bottom / Latest, keyboard up and down, auto-load at the top, and row-state remounts. The full log is in `/tmp/scroll-council/step2/LOG.md`.

## Known limits
- Reopening a chat that is still running lands at its bottom rather than at the saved reading position. The eager stack does the same, so this is not caused by windowing.
- Artefact web views are still cached without eviction, so unmounting a row does not free its WKWebView.
- `cachedImage(for:)` still decodes base64 attachment payloads synchronously on main.
- A chat whose rows are all very tall mounts few rows. Mount cost per band move depends on the heaviest rows (big code blocks, tool groups).
