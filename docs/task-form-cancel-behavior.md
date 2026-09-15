# Task form Cancel behavior — how it works

This documents the shared "compose sheet" pattern used by every parent-facing
task/rule/event form in the app (New Task, Edit Task, Redo note, Edit Rule,
Add Event), what bug it had, and what changed. Written after fixing a bug
where scrolling aggressively inside one of these forms could dismiss the
whole sheet — the same practical effect as tapping Cancel, except silent and
unintended.

## Where this lives

- `Evlin/Parent/AddFormComponents.swift` — `FormShell`, the shared chrome
  (Cancel top-left, bold title, scrollable field content, full-width Save
  pill) every one of these sheets is built from.
- Callers: `AddTaskSheet` (`ScreenProfile.swift`), `RedoComposeSheet` and
  `EditTaskReviewSheet` (`TaskReviewDeck.swift`), `EditRuleSheet` and
  `EditDailyScreenTimeLimitSheet` (`ScreenProfile.swift`), the Add
  Task/Add Event forms in `ScreenCalendar.swift`.

## The intended design

A parent typing into one of these forms should only ever leave two ways:
tapping **Cancel** (discard) or tapping **Save** (commit). That's why every
`.sheet(...)` presenting a `FormShell`-based view carries
`.interactiveDismissDisabled()` — it turns off iOS's normal "drag the sheet
down to dismiss" gesture, so a stray swipe mid-edit can't silently throw away
what was typed. `FormShell`'s own doc comment states this explicitly: *"No
drag handle here on purpose... Cancel/Save are the only way out."*

## The bug: aggressive scroll could still act like Cancel

`interactiveDismissDisabled()` only disables the sheet's own pan-to-dismiss
recognizer. It does **not** fully isolate that recognizer from every other
drag gesture nested inside the sheet's content — and `FormShell`'s field
list had one such gesture: `.scrollDismissesKeyboard(.interactively)` on its
`ScrollView`.

`.interactively` ties the keyboard's dismissal directly to the scroll drag —
as you drag down, the keyboard tracks your finger and slides away with it.
That's a *continuous interactive pan*, which is the exact shape of gesture
the sheet's own (disabled) dismiss recognizer is built to watch for. Because
the two pans aren't fully isolated from each other in UIKit, a fast/
aggressive downward scroll — especially one starting right after typing,
while the keyboard is still up — could let that drag bleed through and
trigger the sheet's dismissal anyway, even with
`interactiveDismissDisabled()` set. The parent would just see the whole form
close, exactly as if they'd tapped Cancel, without meaning to.

## The fix

Two independent changes in `AddFormComponents.swift`'s `FormShell`:

1. **`.scrollDismissesKeyboard(.interactively)` → `.scrollDismissesKeyboard(.immediately)`**
   The keyboard now drops the instant a scroll drag begins, instead of
   tracking the drag. There's no longer a continuous interactive pan for
   that ambiguity to occur in — scrolling is just scrolling.
2. **Wider Cancel tap target.** The button previously had
   `.frame(minHeight: 48, alignment: .leading)` — tall enough, but no
   minimum width, so the actual hit area was only as wide as the word
   "Cancel" itself. A tap a few points to its right (still visually inside
   the row's empty-looking leading corner) missed. Added
   `minWidth: 72` alongside the existing `minHeight: 48`.

Both changes are in one place (`FormShell`) and apply to every form built on
it — New Task, Edit Task, Redo note, Edit Rule, Edit daily screen-time limit,
Add Event — rather than needing to be patched per screen.

## Why this couldn't be verified with a tap/drag test

This environment has no way to simulate a touch drag gesture on the
simulator (confirmed earlier in this project — only `xcrun simctl`
install/launch/screenshot and code-level state injection are available, no
tap/swipe injection). The root cause was identified by reading the gesture
stack rather than reproducing the drag live, and verified by confirming
`.interactiveDismissDisabled()` was already correctly applied at every
`FormShell` call site (so a missing modifier wasn't the cause) before
tracing the remaining candidate: the interactive keyboard-dismiss gesture
sharing a drag with the sheet's own dismiss recognizer, a known SwiftUI/
UIKit interaction. If this still reproduces on a real device, the next
thing to check is whether `.interactiveDismissDisabled()` needs to be paired
with `.presentationDragIndicator(.hidden)` and a `UIGestureRecognizerDelegate`-level
fix on the hosting `UIScrollView`, which isn't reachable from SwiftUI without
dropping into `UIViewRepresentable`.

## If this needs to be extended later

- To add the same fix to a form that *doesn't* go through `FormShell`, apply
  the same two changes directly: `.scrollDismissesKeyboard(.immediately)` on
  its `ScrollView`, and a `minWidth` on its Cancel button's `.frame(...)`.
- To make Cancel itself safer against *any* accidental trigger (not just
  this specific gesture bleed), the next step would be a
  "Discard changes?" confirmation before actually calling `onCancel()`,
  gated on whether the form has unsaved input — not implemented here, since
  the root cause above was fixed directly, but worth adding if another
  accidental-dismiss report comes in through a different path.
