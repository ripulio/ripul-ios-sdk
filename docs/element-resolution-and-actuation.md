# Finding, recording and actuating elements

How the macro framework locates a UI element, presses it, records that as a
replayable step, and how we know any of it worked. Written after a long day of
getting this wrong in nine distinct ways, so it leads with the failure modes
rather than the design — the design only makes sense as a response to them.

**Audience:** anyone extending the actuation ladder, adding a tool that
addresses elements, or wondering why a control "can't be tapped".

---

## 1. Why this is hard

The naive model is "find the view, send it a tap". Every part of that is wrong on
iOS, for reasons that are structural rather than incidental.

**There is no single tree.** A screen is described by at least three
representations, and none of them is complete:

| Plane | What it knows | What it doesn't |
|---|---|---|
| **View tree** | geometry, classes, controls, gesture recognizers | SwiftUI leaves are anonymous scaffolding — `_UIInheritedView`, zero-area layout containers, views recycled on re-render |
| **Accessibility tree** | identity, text, what is activatable | not views; frames are screen-space; a `UITextView` is a *container*, not an element |
| **Hit-test** | what a finger would actually reach | says nothing about identity, and stops at the first interactive view |

A SwiftUI `Button` may publish an accessibility element with a name and no
corresponding meaningful view; a `UIButton` inside a `UIViewRepresentable` may
publish **no accessibility element at all** while being a perfectly ordinary
`UIControl`. Any strategy that commits to one plane fails on the other's cases.

**Identity propagates, in both directions.** `.uiKitIdentifier` /
`accessibilityIdentifier` do not stay put:

- SwiftUI pushes an identifier **down** onto descendants, overwriting their own.
  A text field stamped `notes.field` intermittently reports `notes.root` because
  its island re-rendered.
- UIKit hosting containers adopt their content's identifier **upward**. A button
  stamped `uikit.button` shares that id with five ancestors up to a 440×894
  full-screen wrapper.

So "the view with this id" is ambiguous by construction, and *tree position
cannot disambiguate it* — the owner is outermost in one direction and innermost
in the other.

**Success is not observable from inside.** `sendActions(for: .touchUpInside)` on
a control with no targets returns nothing and does nothing.
`accessibilityActivate()` on a container may return `true` having activated a
sibling. Selecting a `List` row does nothing at all unless there's a selection
binding. Every one of these *reported success* at some point in this SDK's
history, and each produced a macro step that replayed as a silent no-op forever.

---

## 2. Architecture

Three stages, deliberately separate, because conflating them is what produced
most of the bugs.

```
    point or predicate
            │
    ┌───────▼────────┐
    │    RESOLVE     │   what element is this?        ScreenElementFinder
    └───────┬────────┘
            │ two values: target + actionable
    ┌───────▼────────┐
    │    ACTUATE     │   make it do its thing         ScreenActuationEngine
    └───────┬────────┘
            │ outcome + trace
    ┌───────▼────────┐
    │     RECORD     │   name it durably              MacroSelector / MacroRecorder
    └────────────────┘
```

### 2.1 Resolve — two values, not one

The single most important design decision, and it came from the user rather than
from us: **resolution produces two answers, not one compromise.**

| Value | Meaning | Consumed by |
|---|---|---|
| `currentTarget` | the closest **element** to the point | outline, identity readout, theme tools |
| `currentActionable` | the closest **actionable** element | fire, macro record, replay |

They frequently differ. A panel carries a disclosure gesture *and* contains a
text field; the element you selected is the panel, the thing a tap drives is the
field. Before this split, one value had to serve both masters and served neither:
ranking by "actionable" broke theme selection (labels and backgrounds are valid
selections that will never respond to a tap), and ranking by "closest" made every
tap hit a container.

When they diverge the explorer says so **both ways** — an `actionable:` line in
the readout and a dashed teal box beside the pink selection box — so you see it
*before* pressing rather than discovering it by watching a panel collapse.

Three states, three distinct readouts. Silence must never mean two things:

| State | Readout | Outline |
|---|---|---|
| selection is itself pressable | `actionable: this element` | pink |
| something else would be pressed | `actionable: <named element>` | pink + dashed teal |
| nothing responds to a tap | `actionable: none — nothing here responds to a tap` | grey |

### 2.2 Finding by predicate

`ScreenElementFinder.find(id:text:)` and `find(_ query:)` walk **the window**,
not `rootViewController.view`. A modally presented view controller's view lives
in a presentation container that is a *sibling* of the root controller's view, so
a walk rooted at the root controller cannot see presented content at all. That
single fact made every modal invisible to the entire element layer until 0.7.30.

Matches are ranked **most specific first**:

1. a `UIControl` or text input — it *is* the thing
2. a view with its own text content — probably the thing
3. an accessibility element
4. anything else — scaffolding that adopted the name

then by tighter frame, then by tree order (stable, so `nth` selectors keep
meaning). This is what resolves the both-directions propagation problem without
having to know which direction applied.

**Lookup matches the raw `accessibilityIdentifier`; display uses
`identifier(of:)`,** which suppresses a borrowed id so the readout never presents
an ancestor's identity as the element's own. Using the display helper for lookup
suppresses exactly the innermost view that owns the name — that bug aimed the
reticule at the centre of the screen for eleven conformance runs.

### 2.3 Actuate — the ladder, split into resolve + actuate

**Coordinates get exactly two legal homes: inside `resolveTap`, and inside an
explicit element-relative anchor (§2.4).** The point is a *discovery-time*
input — the user aiming the reticule is a strong signal for finding an
element, and a terrible thing to store or act on afterwards.

`performTap` is now a shim over two stages:

- **`resolveTap(on:matchId:matchText:at:)`** — side-effect-free candidate
  discovery. Every rung that consumes the point (point-targeted elements,
  bands, hit-test, island locality) lives here, in the historical rung order
  below, and emits typed `TapCandidate`s (control / focus / a11y element /
  gesture / row-select), deduped so an element that declines once is never
  re-probed. It also computes `pointMattered` — whether the point, rather than
  identity, chose the outcome — which is what gates anchor recording.
- **`actuate(ResolvedTarget)`** — a kind-dispatched executor that walks the
  candidates and returns the first that genuinely works, with the same wiring
  honesty as before. **It never sees a coordinate.**

One caveat keeps `actuate` from being a pure function of promises:
`accessibilityActivate()` *performs* the action rather than reporting whether
it could, so a11y candidates are discovered at resolve but remain try-and-see
at fire time. The readout distinguishes the two ("actionable: …" is a promise;
"untested — N accessibility candidates" is not).

The explorer's `currentActionable` is no longer a parallel computation: the
pick calls `resolveTap`, and the readout, the teal box **and the fire** all
consume that one `ResolvedTarget`. The readout is a promise the actuator keeps
by construction — difficulty #3 below is fixed structurally, not procedurally.

Every rung appends to a `trace` string, which is the primary debugging
artefact and is surfaced in the fire pill, the recording error dialog, and the
conformance report.

| # | Rung | For |
|---|---|---|
| 1 | `UIControl` target/action | ordinary UIKit controls |
| 2 | accessibility element in the target's own subtree | SwiftUI leaves with one element |
| 2a | focus self | text inputs — tapping a field *means* focusing it |
| 2b | accessibility ancestor climb | stamped leaves whose element lives above them |
| 2c | point-targeted accessibility element | anonymous SwiftUI leaves — the point is the only signal |
| 2c-band | accessibility element **beside** the point | leading-aligned control in a full-width row |
| 2d | lone element in the SwiftUI island | stamped leaf whose own subtree is empty |
| 3 | `accessibilityActivate` up the chain | generic fallback |
| 3-bis | **view band** — real control beside the point | controls publishing no accessibility element |
| 3-ter | **hit-test** — ask the platform | anything the tree walks can't reach |
| 4 | tap gesture recognizers | custom gesture-driven views |
| 5 | container row selection | table/collection cells |

Two invariants hold across every rung, and both were learned the hard way:

- **Locality.** A rung with no reference to the point has no business in a
  point-resolution ladder. Path 2d ("the lone element in the island") had none:
  it was accidentally safe inside a `List`, where every row is its own island,
  and pressed one button from anywhere on screen once the screen was a single
  island. *Being last makes a rung late, not safe.*
- **Wiring.** Never report success for an action nothing is listening to. Check
  `allControlEvents` — it reflects block-based `addAction` handlers as well as
  target/action, and is empty for SwiftUI's `HostingUIButton`, which handles
  presses internally and silently swallows `sendActions`.

**Ambiguity, not distance, is the safety rule.** A distance cap is wrong in both
directions and no constant is discoverable: 300pt pressed a switch 148pt away in
the wrong row; 96pt then refused one 119pt away in the *right* row. What
separates them is that when the point is level with exactly one control, that
control is what was meant however wide the row is; when it is level with several,
no distance argument can choose, and guessing has already been wrong. So: reach
anything the point is level with, refuse an ambiguous band, and name the
contenders in the trace.

### 2.4 The anchor exception — element-relative, never screen

Some taps genuinely need the point at replay time: two wired, unnameable
controls inside one nameable container (a custom split control, a canvas-like
row) — no id, no text, no accessibility element on either, so the selector can
only name the container and the point decides which half was meant.

`MacroAnchor` is the sanctioned form of that exception:

- **fractions of the element's own bounds**, from the **leading** edge (an
  LTR-recorded anchor lands on the mirrored control under RTL) and the top;
- **resolved against the element's LIVE frame** at the moment of firing —
  `LiveScreenResolver.performTapDetailed` is the only place an anchor becomes
  a point, immediately before `resolveTap` consumes it. The element moving or
  resizing between record and replay is the normal case, not the edge case;
- **recorded only when `pointMattered`** — the resolve stage found the first
  meaningful candidate by the point *and* more than one point-eligible object
  in reach — and only when the selector wasn't upgraded to the activated
  element's own identity. A tap that identity can replay carries no anchor.
  The exception must stay exceptional, or every step silently becomes a
  coordinate tap again.

### 2.5 Value-bearing controls

Some controls are not tappable at all — they are **settable**. Mechanically
driving a date picker's wheels cannot be done through public API and would be an
elaborate route to what one property assignment produces exactly:
`UIDatePicker.date` plus `.valueChanged` delivers the same value to the same
handler a real spin does.

`set_value` covers `UIDatePicker`, `UISwitch`, `UISlider`, `UIStepper`,
`UISegmentedControl`, `UIPickerView`, and text inputs. It is exposed as a tool, a
macro step kind, **and** an option in the double-tap recording chooser — offered
only where a value-bearing control actually exists. A step you cannot record is
not a step the recorder has.

### 2.6 Record

`MacroSelector(describing:)` synthesises a durable selector using the same facts
matching reads:

1. id alone, when present — tightest and most stable
2. role + visible text
3. role + `accessibilityLabel` — where tab items and icon-only buttons keep their
   name
4. role + class + `nth`, computed against the live tree — so "the third tab
   button" replays as exactly that instead of failing ambiguous

Then the critical step: **record what was actuated, not what was under the
cursor.** An anonymous SwiftUI leaf is unnameable from the view tree, so a
synthesised selector degrades to `class=_UIInheritedView`, which matches nothing
(or everything) on replay. `upgrade(_:with:)` replaces such a selector with the
identity of the accessibility element the tap actually activated.

Recording also **live-executes** the action. If it doesn't work now, recording it
wouldn't make it work later — and the developer sees their own app respond.

---

## 3. How we know it works

This is the part that took longest to get right, and it is worth more than any
individual rung.

### The conformance harness

`RipulConformanceScreen` presents one of every control **archetype** — the shapes
a tap can mean something different for:

| | |
|---|---|
| UIKit | `UIButton`, `UITextField`, `UITextView`, `UISwitch` |
| SwiftUI | `Button`, `TextField`, `Toggle`, `onTapGesture` view, inert `Text`, button in a nested island |

`explorer_conformance` drives the **reticule** to each one, presses it, and scores
it. Design points that matter:

- **Reticule, not `tap_element`.** Addressing by id exercises different machinery
  from point resolution. Verifying a point-resolution fix via an id-based tool
  tests code that was never broken — we did that for eighteen releases.
- **Presented as a modal**, in the **app window**. Presented content was invisible
  to the element layer until 0.7.30, so exercising a modal is the point. And it
  must be *app* content: presenting it via the chrome-preferring presentation
  root put it in a window the finder is explicitly forbidden to read (0/10 on ten
  controls that were never examined).
- **Inert rows pass by being inert.** A label refusing a tap is correct — theme
  tools select labels constantly. It passes only if *nothing anywhere fired*.

### The oracle principle

**Ask the app, never the engine.**

The engine's success flag is necessary and never sufficient. Every archetype
records the effect the *platform* produced — a control action, a
`textFieldDidBeginEditing`, a `.valueChanged`, a toggle state change — into
`RipulConformanceLog`. The sweep clears it before each probe and asserts the
archetype's own token appeared.

This is the change that made the number mean something, and it earned its keep
immediately by catching, in turn:

| Failure mode | What it caught |
|---|---|
| false pass | four rows "passing" by selecting a `List` row, which does nothing |
| wrong target | aimed at a button, pressed a switch 148pt away, reported success |
| press-from-anywhere | eight archetypes all firing one button at the bottom of the screen |
| false **negative** | a field genuinely focused, scored a miss because the oracle watched the wrong signal |

That last row is the trap in an app-effect oracle and deserves equal weight: it
can produce false negatives as easily as the engine produced false positives. An
oracle that looks in the wrong place fails exactly like the bug it exists to
detect, makes working code look broken, and invites a fix for a defect that isn't
there. **"The number went down" is not self-evidently progress.**

Corollary: prefer platform ground truth over framework bindings. First-responder
state beats `@FocusState`, which tracks SwiftUI's own focus system and misses a
UIKit field focused directly.

---

## 4. What has been difficult

Ranked by cost, not by how interesting they are.

**1. No observability (by far the largest).** For a long stretch the only
instrument capable of seeing the failing path was a human with a phone,
describing a symptom. Each gap cost a round trip, a release and an install. Four
hypotheses were shipped at one bug without one of them being tested. The
`explorer_probe` tool — which drives the reticule programmatically and returns the
readout *verbatim* — found the actual cause on its first call.

**2. One resolution, several consumers, fixed one at a time.** The most reliable
recurring mistake, three times in one day:

- highlight / fire / readout each computed their own answer, and drifted
- the tap consumers were moved to the actionable view; the **type** consumer was
  left on the token anchor
- `setValue` shipped with engine, tool and replay — and no **chooser** entry
- 0.7.53 fixed inherited identity for the **readout** and never applied it to
  **lookup**

The lesson is procedural, not architectural: *"which other callers read this?"*
is a required step, not a good habit.

**3. Two places encoding one policy.** The explorer's `actionable` computation and
the actuator's ladder both reasoned about the scroll boundary, separately, and
disagreed — the readout promising a press the actuator would refuse. Fixing it in
one direction promptly recreated it in the other (pessimistic instead of
optimistic), and the sweep then believed the *prediction* over the measurement.
**A prediction must never gate a measurement.**

**4. The instrument measuring itself.** Five of the first six conformance runs
were about the harness, not the SDK: presented into the wrong window; stale SDK
from a broken pin bump; scoring gated on a prediction; a `List` recycling cells
and reflowing under the keyboard so later archetypes were aimed at frames that
had moved. A measuring instrument has to be right before it can be realistic.

**5. Verification theatre.** A green build proves nothing about a behavioural SDK
change. `Package.resolved` is a lockfile: rewriting its version string while
leaving the old revision hash shipped 0.7.55 source under a 0.7.56 label, with
every file we looked at reading correct. The only signal that catches it is the
**running** `sdk:` stamp on the device.

There is a second flavour of this, and it cost a whole run: **measuring the
wrong app.** WAC ships prod (`com.WAC`) and beta (`com.WAC.beta`) side by side
with separate bundle ids, and `ship-wac.sh`'s device path installs **prod
only** — so a sweep aimed at "the device" answered from a beta build pinned to
an SDK two releases old and scored 5/10. Nothing in the number said so; the
`sdk=0.7.67` stamp and a missing anchor phase did. A sweep runner should
therefore **gate on the target's identity before it fires**: ask
`device_get_app_diagnostics` for the bundle id and build number, and refuse to
run until they match what was just installed.

---

## 5. Where we are, and the path to 100%

Current (0.7.70): **12/15** — eleven archetypes plus the four anchor rows,
every pass confirmed by the app's own handler firing. The count went UP by a
failing row on purpose: the plain-`.accessibilityIdentifier` Button added in
0.7.70 turned an assumption into a visible red row (see (a-bis)).

| Archetype | Status |
|---|---|
| UIKit `UIButton` | pass — rung-1 wiring now sees block `addAction` handlers |
| UIKit `UITextField`, `UITextView` | pass — `focus` |
| UIKit `UISwitch` | pass — rung 1 toggles + `.valueChanged` directly |
| SwiftUI `TextField` | pass — `focus`, verified via first responder |
| SwiftUI `Toggle` | **pass — real press** (was the false-pass family) |
| SwiftUI inert `Text` | pass by correctly staying inert |
| Nested-island button | pass — readout pessimistic (a11y candidates are try-and-see) |
| All four anchor rows | pass — locality, exception gating, replay-after-move, stale-point proof |
| SwiftUI `Button` | **fail — honestly now**: the pick lands on the 17pt stamp, whose island publishes one element belonging to a *different* island 166pt away, so nothing is level with the point — see (a) |
| SwiftUI `Button` (plain `.accessibilityIdentifier`) | **fail — not even findable by id**, though findable by text. See (a-bis): this one is a *lookup* gap, not an actuation one |
| SwiftUI `onTapGesture` | **platform limit** — now declines instead of falsely succeeding |

### The three open problems

**(a) `SwiftUI Button` resolves no candidate at all.** This has inverted since
the space veto landed. `Toggle` now **passes for real** via
`accessibilityElement(ancestor)`, and `Button` **fails honestly** where it used
to pass by container-luck (activating `PlatformGroupContainer` and happening to
be the first element inside it — scored by whether it got lucky).

The measured trace names the cause precisely, and it is *not* the ancestor rung:

```
target=UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<UIKitIdentifierStamper>>@0,0,408,17
host=HostingView  pt=220,510  seen=1{Nested island button@16,676,134,17}
resolve:1cand[chain]  chain:no
```

Two facts to chase. The pick lands on the **stamp** — a 17pt-tall
`UIKitIdentifierStamper` platform view, not the button — so `hostingAncestor`
returns the stamp's own tiny island. And that island's accessibility walk
returns exactly one element, which belongs to a **different island 166pt away**
(the nested-island button at y=676, while the point is at y=510). So every
point rung correctly finds nothing level with the point, and only the blind
`chain` candidate survives. The fix is in *resolution* — reaching the real
button's island from the stamp — not in adding another actuation rung.

**(a-bis) A plain `.accessibilityIdentifier` is invisible to `find(id:)`.** Found
by adding an A/B archetype — the same `Button`, identified with SwiftUI's own
`.accessibilityIdentifier` instead of `.uiKitIdentifier`, to test whether the
stamp was the culprit in (a). The experiment could not run, and that *is* the
finding: the row reports `not-on-screen`, yet `wait_for_element` locates it by
**text** in 7ms inside `_UIHostingView<RipulConformanceView>`. It is on screen;
it simply cannot be addressed by its own id.

The cause is the same both-planes problem the doc opens with: SwiftUI's
`.accessibilityIdentifier` lands on the accessibility **element**, not on any
`UIView.accessibilityIdentifier`, and not in the `UIKitIdentifierRegistry`. The
identity ladder's third rung (`accessibilityIdInTree`) is meant to cover this
and evidently does not reach it.

This is worse than (a) in blast radius, because it is a **lookup** gap, not a
point-resolution one: `tap_element id=…`, `wait_for_element id=…` and macro
replay by id all fail for any control identified the plain SwiftUI way — which
is what a client app that never imported our stamp modifier will naturally
write. The fix is to match a view's published accessibility elements'
identifiers as a rung of `find(id:)`, resolving back to the host view.

**(b) `onTapGesture` is a genuine platform limit.** SwiftUI registers no
accessibility action for a bare `onTapGesture` and attaches the recognizer to a
hosting *ancestor* that resolves by touch location, so there is nothing beneath
the element to fire and nothing to activate. Reaching it requires either
synthetic touch injection (deliberate, invasive, needs its own decision) or an
app-side remedy — `.accessibilityAddTraits(.isButton)` or an explicit
`.accessibilityAction`. **We should document this as an SDK integration
requirement rather than paper over it**, and have the readout say so when it sees
the shape.

**(c) Restore `List` coverage.** A `List` was removed from the harness to get a
trustworthy baseline; it was concealing the island bug, which is a reason to
*test* it, not avoid it. "Control inside a recycled `List` row" should return as
its own archetype.

### Beyond the current ten

100% of ten archetypes is not 100% coverage. The archetype set should grow toward
what clients actually build:

The anchor phase (shipped with the resolve/actuate split) added the first of
these: **the split control** — two wired, anonymous halves in one stamped
container, with a sweep that records selector + anchor, *moves and resizes the
container*, and asserts the anchored replay still fires the same half while
the stale screen point provably no longer covers it. Four rows in the report:
locality, exception-stays-exceptional (`pointMattered` true for the split,
false for an off-centre tap on a named button), replay-after-move, and the
geometric stale-point proof.

- controls in a recycled `List` / `UICollectionView` cell
- controls inside a `Menu`, context menu, and `.sheet` / `.popover`
- a control behind a `.disabled(true)` — actuation must **refuse**, and say why
- custom `UIControl` subclasses with no accessibility at all
- `NavigationLink`, `Picker`, `Stepper`, `Slider`, segmented controls
- controls in a horizontally-scrolling row (the band's level-with test assumes
  vertical rows)
- an element that moves *during* actuation (the staleness case that made a second
  tap press the wrong thing)

### The principles to hold

Everything above reduces to five rules. They are cheap to state and were all
expensive to learn.

1. **Ask the platform.** `hitTest` is the resolution a finger triggers;
   first-responder is the truth about focus. We spent eleven rungs approximating
   answers UIKit already gives.
2. **Ask the app whether it worked.** Never the engine. A false success is worse
   than a failure — it produces a macro that replays as a silent no-op.
3. **Locality is not optional.** Any rung that can act without reference to the
   point will eventually act on the wrong thing.
4. **Refuse ambiguity, and say what you refused.** A refusal that names the
   contenders beats a press that might be wrong.
5. **One fact, one place, all consumers.** When a rule changes, find every caller
   before shipping. This is the mistake we make most.
