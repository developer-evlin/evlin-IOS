# Child status model & confirmation cards — backend handoff

Written for whoever (person or agent) is building a real backend for this
app. Everything described here is currently **client-only, in-memory, and
non-authoritative** — a `Child`'s `status` is just a `@Published` enum field
that any code in `ScreenProfile.swift` can set directly, with no server
round-trip, no auth check, and nothing surviving a relaunch. This doc exists
so a backend can reproduce the *exact same rules* server-side (as real
endpoints with real authorization) instead of guessing at them from the UI.

Source of truth for everything below: `Evlin/Data/FamilyData.swift`,
`Evlin/Data/TaskData.swift`, `Evlin/Parent/ScreenProfile.swift`. Line
references are to `ScreenProfile.swift` unless stated otherwise.

## 1. The `Child` entity

```swift
final class Child {
    let id: String                             // "liam" today — see note below
    var name: String
    var age: Int
    var dailyLimitMin: Int                      // daily screen-time allowance, minutes
    var color: Color                            // avatar circle color, cosmetic
    var status: ChildStatus                     // see §2 — the field this doc is about
    var timeLeft: String                        // display string, e.g. "45m" — derived, not authoritative
    var timePct: Int                            // 0-100, how much of dailyLimitMin remains
    var usageTodayMin: Int                      // minutes actually used today
    var tasksDone: Int                          // LEGACY — not kept in sync, don't port this field's semantics
    var tasksTotal: Int                         // LEGACY — same as above
    var subtitle: String                        // cosmetic list-row text
    var reflection: ChildReflection?            // non-nil = child is in the reflection flow (see §2.5)
    var downtimeUntil: String?                  // set only when status == .downtime; end-of-schedule display string
    var parentApprovalStatus: ParentApprovalStatus  // .none | .pending | .approved — see §3.1
    var devices: [RegisteredDevice]
    var trialExhausted: Bool                    // demo-only flag, not computed from real billing
    var needsProtectionSetup: Bool              // demo-only flag, not computed from real device state
    var avatar: UIImage?
    var rules: [ChildRule]                      // see §4
}
```

**Don't port `tasksDone`/`tasksTotal`** — they're stale legacy fields the
current code no longer reads for anything user-facing. The real "done"
count is always computed live from the task list (`todaysTasks.filter {
$0.state == .done }.count`, `ScreenProfile.swift:72`). A backend's schema
should just make that a query, not a stored/synced counter.

**On the id**: several other files hardcode the literal string `"liam"` as
this app's one child id (`CalendarData.swift`, `NotificationsData.swift`,
`ScreenChat.swift`'s `FamilyStore.child("liam")`). A real backend obviously
needs real generated ids — just know that those three files currently
assume this exact literal and would need updating in lockstep, they're not
something the backend model needs to preserve.

## 2. `ChildStatus` — the four states, and exactly what each means

```swift
enum ChildStatus: String {
    case unlocked
    case locked        // raw value: "locked"
    case lockedTasks    // raw value: "locked-tasks"
    case downtime
}
```

| Case | Meaning | Screen-time gating | Set by |
|---|---|---|---|
| `.unlocked` | Kid's devices are usable, normal daily allowance applies | Not blocked (until `timePct` hits 0, in a real implementation) | Child creation; approving all tasks; manual unlock; downtime ending |
| `.locked` | Parent manually locked the phone — a deliberate pause, unrelated to tasks or time | Fully blocked | Parent tapping "Tap to lock phone" while `.unlocked` |
| `.lockedTasks` | Blocked specifically because there's outstanding/unreviewed work | Fully blocked | The child's first-ever task being assigned; any task moving to `.pending`/`.overdue`/`.review`/`.bypass` while nothing else already explains being locked |
| `.downtime` | Blocked by a schedule (the built-in Downtime rule), not a one-off decision | Fully blocked until the schedule's end time | Not actually set anywhere in current code from a live schedule check — see §4.1 gap note |

There is **no automatic status-computation engine** in the current app —
`status` is a plain field, mutated by explicit code at specific event sites,
enumerated in full in §3. A backend replacing this should model these as
real state-machine transitions triggered by real events (task created, task
approved, parent action, schedule tick), not a client-computed derived
value — but the *transition table* itself (§3) should be preserved exactly,
since that's the actual product behavior already validated in this build.

Also relevant but **not part of `ChildStatus`** — two more binary
conditions that combine with it in the UI (`headerCard`,
`ScreenProfile.swift:398-497`):
- **`screenTimeLimitOff`** (`ScreenProfile.swift:109`) — `true` when the
  built-in Screen Time Limit rule (`ChildRule.kind == .screenTimeLimit`) is
  toggled off. While true and `status == .unlocked`, the daily cap doesn't
  apply at all for the rest of the day (see §5.5). This is a rule-level
  flag, not a `ChildStatus` case — a child can be `.unlocked` with the
  limit either on or off.
- **`allTasksAwaitingReview`** (`ScreenProfile.swift:82-86`) — `true` when
  every due-today task is either `.review`/`.bypass` (submitted, waiting on
  the parent) and none are still `.pending`/`.overdue`. This doesn't change
  `status` itself, but it's what makes `headerCard` show **Approve All**
  instead of the lock/unlock button — i.e. it's a *UI-affordance* condition
  layered on top of `.lockedTasks`, not a separate status.

### 2.5 The fifth de-facto state: reflection

`child.reflection != nil` isn't a `ChildStatus` case, but functionally
behaves like a fifth locked state — while set, `ScreenProfile.swift:130-134`
swaps the entire tasks section for `reflectionSummaryCard` and the header's
status line shows "Under Reflection" instead of any `ChildStatus`-derived
text. A backend should probably decide up front whether reflection is a
`ChildStatus` case of its own or a genuinely separate "in reflection" flag
that can co-exist with (override the display of) any `ChildStatus` — the
current code treats it as the latter, and nothing in the current code
clears it automatically; only the parent's own "Cancel reflection" action
does (`child.reflection = nil`, `ScreenProfile.swift:587`).

## 3. Every place `status` (or a co-condition) actually changes

This is the complete list — nothing else in the codebase writes
`child.status`, `child.parentApprovalStatus`, `child.reflection`, or a
`ChildRule.on` flag that affects locking.

| # | Trigger | Code location | Effect |
|---|---|---|---|
| 1 | Child created (onboarding, or Settings "Add a child") | `FamilyStore.addOnboardedChild` (`FamilyData.swift:128`) | `status = .unlocked`, `dailyLimitMin = 60`, `tasksTotal = 0` |
| 2 | Parent assigns the child's **first-ever task** | `AddTaskSheet.onCreate`, `ScreenProfile.swift:298-316` (`isFirstTask = tasks.isEmpty`, checked *before* the append) | `status = .lockedTasks`. **`dailyLimitMin` is deliberately left untouched** — it may have already been customized in Rules before any task existed, and this must not stomp it |
| 3 | Parent taps "Approve All" | `approveAllPendingReview()`, `ScreenProfile.swift:92-103` | Every due-today task in `.review` → `.done`, every `.bypass` → `.bypassed`; then `status = .unlocked`, `timeLeft` reset to full `dailyLimitMin`, `timePct = 100` |
| 4 | Parent taps "Tap to lock phone" while `.unlocked` | `headerCard`'s `LockActionButton` action, `ScreenProfile.swift:463-471` | `status = .locked`. Does **not** touch `timeLeft`/`timePct` — a manual lock banks whatever time was left rather than spending it |
| 5 | Parent taps "Tap to unlock phone" while locked **and** tasks are still outstanding | Same button, `ScreenProfile.swift:472-477` | Does not unlock directly — sets `showUnlockConfirm = true`, which shows `UnlockConfirmCard` (§5.2). Confirming there (`onUnlock`, `ScreenProfile.swift:174-179`) sets `status = .unlocked`, `timeLeft` reset to full, `timePct = 100` |
| 6 | Parent taps "Tap to unlock phone", tasks are done, and there's still banked time left (`timePct > 0`) | `ScreenProfile.swift:478-485` | `status = .unlocked` immediately — no confirm needed, since this is just resuming a paused manual lock, not overriding open work |
| 7 | Parent taps "Tap to unlock phone", tasks are done, and the daily allowance is fully used (`timePct == 0`) | `ScreenProfile.swift:486-492` | Doesn't unlock directly — sets `showGrantTimeSheet = true` (`GrantExtraTimeSheet`, §5.3). Confirming there (`onGrant`, `ScreenProfile.swift:194-199`) sets `status = .unlocked`, `timeLeft`/`timePct` set from the granted minutes |
| 8 | Downtime rule toggled off, or deleted | `exitDowntimeIfActive()`, `ScreenProfile.swift:505-511`, called from the rule toggle (`ScreenProfile.swift:657`) and the rule-delete flow (`ScreenProfile.swift:684`) | Only acts `if child.status == .downtime`: sets `status = .unlocked`, `timeLeft` reset to full, `timePct = 100`, `downtimeUntil = nil` |
| 9 | Kid taps "Parent Controls" on their own tablet (kid-side, sets the *parent*-side flag) | `parentApprovalStatus = .pending` (kid side, `ScreenTabletHome.swift` — not in this file) | Shows `approvalBanner` (§5.1) on the parent's profile |
| 10 | Parent taps "Approve" on `approvalBanner` | `ScreenProfile.swift:360-362` | Doesn't flip approval immediately — sets `showApprovalVerify = true`, showing `ParentApprovalVerifyingOverlay` (§5.6), a ~1.5s mocked "verifying" beat with **no real biometric/auth check** (see its own comment — being physically inside the child's profile *is* treated as the factor). Its completion callback (`ScreenProfile.swift:218-223`) sets `parentApprovalStatus = .approved` |
| 11 | Parent taps "Not now" on `approvalBanner`, or taps the dimmed backdrop | `ScreenProfile.swift:336`, `:363-365` | `parentApprovalStatus = .none` |
| 12 | Screen Time Limit rule toggled off | `ScreenTimeOffConfirmCard` (§5.5) confirm | `child.rules[idx].on = false` for the `.screenTimeLimit` rule — does not touch `status` itself, only the `screenTimeLimitOff` co-condition described in §2 |
| 13 | Parent approves the **last** outstanding task one at a time inside `TaskReviewDeckView` (the swipeable per-task review queue, opened from a task row or a notification tap — a separate file from `ScreenProfile.swift`) | `unlockIfEverythingResolved()`, `TaskReviewDeck.swift:247-255`, called after every single approve (`TaskReviewDeck.swift:236`) | Only fires while `status == .lockedTasks` specifically (checked explicitly — a parent's own manual `.locked` is a separate deliberate decision this must never override). Checks no task is still `.pending`/`.review`/`.overdue`/`.bypass`; if none are, `status = .unlocked`, `timeLeft` reset to full, `timePct = 100`. This is the **one-at-a-time equivalent of row 3** (bulk Approve All) — both must independently reach the same end state, and a backend needs both call sites (or a single shared server-side check triggered by every individual approval) to keep them in sync |

**Correction to an earlier draft of this doc**: the paragraph above (row 13)
was missing from the first version of this table — a review of the whole
codebase for every place that mutates `child.status`/`ChildTask.state`
found it in `TaskReviewDeck.swift`, a file this doc had not otherwise
covered. `TaskReviewDeck.swift` also has its own `applyRedo`/`applyEdit`/
`applyDelete` functions (`TaskReviewDeck.swift:257-274`) — mundane
edit/delete/redo-to-pending task mutations, not status-affecting beyond
row 13, but worth knowing this file is a second real write-path into the
same `TaskStore` cache `ScreenProfile.swift`'s `AddTaskSheet` writes into,
not just a read-only review UI.

**Important for a backend design**: notice that steps 5/7/9/10 are all
**two-phase** — a UI gate (confirm card / verifying overlay) sits between
"parent's intent" and "state actually changes." A real backend almost
certainly wants these as two real steps too (e.g. `POST
/children/:id/unlock/request` → client shows the confirm UI → `POST
/children/:id/unlock/confirm` only fires the real state change), both for
parity with this UX and because a naive single-endpoint design would let a
client skip the intentional friction/authorization step entirely.

## 4. `ChildRule` / `RuleKind`

```swift
enum RuleKind { case downtime, custom, screenTimeLimit }
struct ChildRule {
    let id: String
    var kind: RuleKind
    var icon: String
    var title: String
    var detail: String       // free-text display line, NOT derived from other fields — see gap below
    var on: Bool
    var downtimeFrom: Date   // only meaningful for kind == .downtime
    var downtimeTo: Date     // only meaningful for kind == .downtime
}
```

Every child gets exactly two rules seeded at creation
(`TaskStore.rules(dailyLimitMin:)`, `TaskData.swift:99-107`): a
`.screenTimeLimit` rule (`id: "screen-time-limit"`) and a `.downtime` rule
(`id: "downtime"`, fixed 8:00 PM–7:00 AM). Parents can add further `.custom`
rules through chat (not through a form in this file) and edit/delete them
via `EditRuleSheet`.

**Known gap worth flagging to a backend builder**: `ChildRule.detail` is a
**separately-maintained display string**, not derived from
`dailyLimitMin`/`downtimeFrom`/`downtimeTo`. E.g. when the daily limit
changes (`EditDailyScreenTimeLimitSheet.onSave`, `ScreenProfile.swift:692-697`),
the code has to *also* manually rewrite `child.rules[idx].detail = "\(...)
per day"` — nothing keeps these in sync automatically. **A backend schema
should almost certainly compute this display string from the structured
fields instead of storing it redundantly** — this is exactly the kind of
inconsistency a real data model fixes that the prototype couldn't.

**Also flagging**: `ChildRule`s aren't only created/edited through
`rulesSection`'s `EditRuleSheet`. `Evlin/Parent/ScreenChat.swift:1088`
(the mocked AI chat's "block an app" flow) appends a `.custom` rule
directly onto `FamilyStore.child("liam").rules` from a completely
different screen, with its own inline `id`/`icon`/`title`/`detail`
construction rather than going through any shared "create a rule"
function. **There is no shared rule-creation function to reuse** — a
backend's "create rule" endpoint needs to serve both this chat path and
the Settings/Profile path, since the current code has two independent call
sites doing the same append by hand.

Separately, and specifically worth flagging since it looks like it should
write data and doesn't: chat's **"Add a task" card is entirely cosmetic**.
`ScreenChat.swift`'s `handleAddTask` (`ScreenChat.swift:1098-1104`) only
posts a confirmation chat message ("Added \"...\" for Liam...") — it never
calls `TaskStore.binding(for:)` or appends a `ChildTask` anywhere. Tapping
that card does **not** actually create a task, does **not** trigger row 2
of the table above, and does **not** show up in `ScreenProfile`'s task
list afterward. Don't assume a network call behind this card is a
drop-in replacement for something that already works locally — the local
version doesn't do anything either.

**Also flagging**: the Downtime rule's `on`/`downtimeFrom`/`downtimeTo`
exist, but nothing in the current codebase actually flips `status` to
`.downtime` based on a live clock check against them — `.downtime` is a
real, handled `ChildStatus` case throughout the UI, but the trigger that
would set it from "current time is within `downtimeFrom`...`downtimeTo`"
doesn't exist yet in this prototype. A backend needs to implement that
schedule check for real (presumably a server-side cron/scheduled job per
child, or an on-device check via a Screen Time API for real device
enforcement) — don't assume you can find that logic to port, it isn't
there.

## 5. The cards — trigger, purpose, and what confirming does

All styled identically on purpose (a floating white card over a `black
opacity(0.32)` scrim, dismissible by tapping the scrim) so they read as one
consistent "this is a deliberate moment" language — worth preserving that
UX pattern for any of these you turn into real confirm-before-mutate flows.

### 5.1 `approvalBanner` (`ScreenProfile.swift:332-382`)
- **Shown when**: `child.parentApprovalStatus == .pending`.
- **Body**: "`{name}` wants Parent Controls" / "Passwordless approval" /
  "Nothing happens on their device until you confirm it's you."
- **Approve** → `showApprovalVerify = true` (leads to §5.6).
- **Not now** / tap scrim → `parentApprovalStatus = .none`.
- **Backend implication**: this is the entire "kid requests elevated
  access, parent must approve from their own device" flow. A real backend
  needs this as a real request object (who requested, when, what for) that
  the parent's approval actually authorizes server-side — right now it's
  just one enum flag with no request payload/reason attached at all.

### 5.2 `UnlockConfirmCard` (`ScreenProfile.swift:1163-1259`)
- **Shown when**: parent tries to unlock while `todaysTasks.count -
  doneCount > 0` (open tasks remain).
- **Body**: "Unlock `{name}`'s devices?" + a warning line stating how many
  tasks are still open.
- **Unlock anyway** → the real unlock (§3 row 5).
- **Cancel** / tap scrim → no-op, dismiss.

### 5.3 `GrantExtraTimeSheet` (`ScreenProfile.swift:882-1105`)
- **Shown when**: parent tries to unlock, tasks are done, but
  `timePct == 0` (daily allowance fully used).
- **Body**: asks for an amount — three presets (15/30/60 min) or a
  scroll-to-pick custom ruler (15-min increments, 15 to 240). Live warning
  banner keyed to the **projected total** (`usageTodayMin + selected`)
  against a fixed 2-hour guideline — three tiers (under 2h / 2h–3h / 3h+)
  with escalating color/copy, not tied to the size of the increment itself.
- **"Give `{X}` more"** → grants that many minutes (§3 row 7).
- **Cancel** / tap scrim → no-op.
- **Backend implication**: if you want the 2-hour guideline messaging to
  reflect a real, parent-configurable value instead of the hardcoded `120`
  constant here, that'd be a new setting to add — currently it's a literal
  in this file (`ScreenProfile.swift:895`).

### 5.4 `ParentApprovalVerifyingOverlay` (`ScreenProfile.swift:1115-1153`)
- **Shown when**: `showApprovalVerify == true` (set by §5.1's Approve).
- **Body**: a Lottie animation + "Verifying it's you…" for ~0.9s, then
  "Approved" + checkmark for ~0.6s, then calls `onDone`.
- **This is entirely a UI timing effect** — there is no real
  authentication call (no biometric prompt, no re-entered PIN). The
  comment in the source is explicit that "being physically inside this
  child's profile *is* the factor" in this prototype. **A real backend
  almost certainly wants a real auth step here** (biometric re-auth, or at
  minimum a session/token check) before actually granting whatever the kid
  requested — don't treat this overlay's existence as proof a real check
  already happens.

### 5.5 `ScreenTimeOffConfirmCard` (`ScreenProfile.swift:1265-1334`)
- **Shown when**: parent toggles the built-in Screen Time Limit rule off.
- **Body**: "Turn off Screen Time Limit?" + warning that this removes the
  daily cap entirely for the rest of today, reapplying tomorrow on its own.
- **Turn off anyway** → `rules[idx].on = false` for that rule.
- **Keep it on** / tap scrim → no-op (toggle visually reverts).
- **Backend implication**: "reapplies tomorrow on its own" implies a
  scheduled reset — same category of gap as the Downtime schedule (§4):
  this prototype has no midnight-rollover job; a backend needs to add one
  (reset `screenTimeLimit.on = true`, reset daily usage counters, etc. at
  local midnight per child/timezone).

### 5.6 `TrialExhaustedPopupCard` (`ScreenProfile.swift:813-873`)
- **Shown when**: `child.trialExhausted == true`, checked once in a
  `.task` the moment the profile screen appears (`ScreenProfile.swift:270`)
  — not reactive to the flag changing while the screen is already open.
- **Body**: "You've used your free trial" / upgrade pitch.
- **Upgrade to Evlin Plus** → a fake 0.9s delay, then `billing.isPlus =
  true` (`BillingState.shared`, a separate singleton, not part of `Child`
  at all).
- **Not now** → dismiss only (`showTrialPopup = false`); does **not**
  clear `trialExhausted` itself.
- **Backend implication**: `trialExhausted` is a hand-set demo flag today —
  a real backend needs actual trial-start-date/entitlement tracking to
  compute this for real, plus a real payment flow behind "Upgrade," not a
  `Task.sleep`.

### 5.7 `ProtectionSetupNeededCard` (`ScreenProfile.swift:749-802`)
- **Shown when**: `child.needsProtectionSetup == true`, same
  once-on-appear `.task` check as §5.6 (`ScreenProfile.swift:271`).
- **Body**: warns the kid could remove/disable Evlin without a device
  Screen Time passcode or Family Sharing enrollment; "Open Screen Time
  settings" deep-links to `UIApplication.openSettingsURLString` (the
  Settings app), not anything in-app.
- **Backend implication**: `needsProtectionSetup` is also a hand-set demo
  flag — real detection of "is this device tamper-protected" would need a
  real Screen Time/Family Sharing API check on the kid's device, reported
  back to the backend, not something the parent's phone can determine on
  its own.

### 5.8 `reflectionSummaryCard` (`ScreenProfile.swift:531-596`)
- **Shown when**: `child.reflection != nil`, replacing the tasks section
  entirely for as long as it's set (see §2.5).
- **Body**: a fixed 3-step flow (`ReflectionStep`: watch video → quiz →
  write reflection, `TaskData.swift:129-148`), showing the kid's submitted
  `writtenText` once present, with Approve/Request-redo actions
  (`r.review`: `"pending" | "approved" | "redo"`, a plain string not an
  enum in the current code) and a "Cancel reflection" escape hatch
  (`child.reflection = nil`).
- **Backend implication**: the quiz's pass/fail check
  (`ReflectionContent.quiz`, needs 4 of 5 correct) currently has no visible
  enforcement point in this file at all — worth checking the kid-side
  reflection UI (not in `ScreenProfile.swift`) for where that's actually
  graded before assuming this parent-side summary is the whole flow.

## 6. Summary: what a backend needs to make authoritative

Everything in §3's table is currently a same-process, no-network mutation
of an `ObservableObject`'s `@Published` field — any of it could be
overridden by "editing the wrong screen," there's no per-action audit trail,
and nothing is actually enforced against the kid's real device (Evlin's
mock "phone is locked" state doesn't call any real Screen Time/
`ManagedSettings` API to actually restrict anything — see
`docs/frontend-architecture.md`'s "Two disconnected worlds" section). At
minimum, a real backend needs:

1. **Real endpoints for each row in §3's table**, each with real
   authorization (only *this* child's paired parent can lock/unlock/approve
   *this* child), not "whoever has the app open."
2. **Server-computed `timeLeft`/`timePct`** from real usage telemetry
   (currently just a stored field nothing feeds from real device usage) —
   this needs either `DeviceActivityMonitor`/`ManagedSettings` reporting
   from the kid's real device, or an honest scope-reduction if that's out
   of scope for now.
3. **The two scheduled jobs this prototype doesn't have**: daily rollover
   (reset usage, reset any temporarily-disabled Screen Time Limit rule) and
   the Downtime schedule check (§4) that should actually flip `status` to
   `.downtime` and back.
4. **A real "verifying it's you" step** (§5.4) if the passwordless-approval
   UX is being kept — the current one is cosmetic only.
5. **Real trial/entitlement + tamper-detection state** (§5.6/§5.7) instead
   of the two hand-set demo booleans.

Everything else — the exact conditions in §3, the exact card copy/flow in
§5, the field shapes in §1/§4 — is what this prototype already got right
and is worth preserving as the target behavior, even as the underlying
storage/enforcement moves from "local mock" to "real backend + real device
API."
