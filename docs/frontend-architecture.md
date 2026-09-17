# Evlin frontend architecture

A from-scratch orientation to this codebase, for an agent (or developer) with
no prior context. Covers what the app is, how it's structured, how data
flows, and what's real vs. mocked. Written after a restructure that moved
the app from "12 hardcoded demo children" to a real single-child flow driven
by onboarding and task events — read the "Status model" section closely if
you're touching anything status-related.

## What this is

Evlin is a SwiftUI iOS prototype for a parent screen-time/task app, modeled
after apps like Bark/Google Family Link. There is **no backend** — every
"device," "pairing," and "sync" concept is mocked in-process. One binary
(`Evlin.app`) serves two completely separate experiences depending on which
role you pick at launch:

- **Parent mode** — the parent's own phone/iPad. Manages one child: tasks,
  screen-time rules, calendar, chat, settings.
- **Child mode** — the kid's own tablet. Shows their tasks, calendar,
  library, submits homework photos.

These two modes share almost no code or data. A task completed on the kid's
tablet does not affect what the parent sees, and vice versa (see "Two
disconnected worlds" below) — this is a known, deliberate limitation of the
prototype, not a bug to silently "fix" without understanding why it's this
way first.

## Entry point and mode switching

- `Evlin/App/EvlinApp.swift` — the `@main` app struct, just hosts `RootView`.
- `Evlin/App/RootView.swift` — the real root of the UI. Owns:
  - `mode: AppMode?` (`.parent` / `.tablet` / `nil` = mode picker)
  - `parentOnboarded` / `childOnboarded: Bool` — session-only, **not
    persisted**. Every fresh launch starts at the mode picker and re-runs
    onboarding for whichever mode you pick. There is no `UserDefaults`/
    Keychain/disk persistence anywhere in this app.
  - Splash screen (`SplashScreenView`) → `ModePickerView` (Parent/Child) →
    onboarding (if not yet onboarded for that role) → the real root
    (`ParentRootView` or `TabletRootView`).

## Onboarding

`Evlin/Onboarding/OnboardingV2Coordinator.swift` drives a step-sequence
per role (`OnboardingV2Role.parent` / `.child`), rendering step views from
`OnboardingV2ParentSteps.swift` / `OnboardingV2ChildSteps.swift`, styled by
`OnboardingV2Theme.swift` and shared chrome in `OnboardingV2Components.swift`
(`OnboardingV2ScreenContainer`, buttons, segmented controls, etc.).

**Everything in onboarding is mocked** — there's no real network pairing.
`pairWithKidCode` is a fake 0.5s delay that always succeeds; every "waiting
for the kid's device" step is a `Task.sleep` standing in for a real
handshake. **The one real side effect** is in `RootView`'s `onComplete` for
the parent chain:

```swift
onComplete: {
    if FamilyStore.children.isEmpty {
        FamilyStore.addOnboardedChild(name: "Liam")
    }
    parentOnboarded = true
}
```

This is what actually creates the family's one real `Child` — see "Status
model" below. The child-role chain (`onComplete: { childOnboarded = true }`)
has no equivalent — it never touches `FamilyStore`, since the kid tablet
side doesn't read from it at all (see "Two disconnected worlds").

There used to be a mandatory "spotlight tutorial" forcing the parent to
create a task before anything else was reachable (a dimmed overlay with a
hole punched over the "+" button). **This has been removed** — a parent
onboarding today lands directly on a normal, fully-interactive Home screen.

## Data model (parent side)

All in `Evlin/Data/FamilyData.swift` and `Evlin/Data/TaskData.swift`.

### `Child` (`FamilyData.swift`)

```swift
final class Child: Identifiable, ObservableObject {
    let id: String
    @Published var name, age, dailyLimitMin, color, status, timeLeft,
                  timePct, usageTodayMin, tasksDone, tasksTotal, subtitle,
                  reflection, downtimeUntil, parentApprovalStatus, devices,
                  trialExhausted, needsProtectionSetup, avatar, rules
}
```

A reference type — `@ObservedObject`/direct field mutation (`child.status =
.locked`) works correctly everywhere it's held. `status: ChildStatus` is
`.unlocked | .locked | .lockedTasks | .downtime` (`.locked` = parent
manually locked it; `.lockedTasks` = locked because of outstanding tasks —
these read differently in the UI, don't conflate them).

`tasksDone`/`tasksTotal` are legacy stored fields, **not kept in sync with
the real task list** — nothing computes them from `tasks` any more. Don't
read them for anything user-facing; use the live task array instead (see
`ScreenProfile`'s `doneCount`/`todaysTasks`).

### `FamilyStore` (`FamilyData.swift`)

```swift
@MainActor enum FamilyStore {
    static var children: [Child] = []   // starts EMPTY
    static func addOnboardedChild(name: String) -> Child   // called from RootView.onComplete
    static func child(_ id: String) -> Child                // safe fallback, never crashes on empty
    static func removeChild(_ id: String)
    static func nextChildColor() -> Color
}
```

`children` is a **plain static array, not `@Published`**. Views that read
it directly won't auto-refresh when it's mutated elsewhere — see "The
familyRefreshTick pattern" below; don't reintroduce the bug it fixes.

In production, `children` holds exactly one `Child`, created by
`addOnboardedChild` at onboarding completion, **unless** a parent uses
Settings' "Add a child" flow to add more (multi-child support still exists
as an opt-in, it's just no longer what onboarding produces by default).

### Status model — how `Child.status` actually changes

This is the core thing that changed in the restructure. There is **no
automatic status-computation engine** — `status` is a plain stored field,
changed by explicit code at specific trigger points. All of them live in
`Evlin/Parent/ScreenProfile.swift`:

| Trigger | Where | Effect |
|---|---|---|
| Child created (onboarding, or Settings "Add a child") | `FamilyStore.addOnboardedChild` | `.unlocked`, `dailyLimitMin: 60` |
| Parent assigns the child's **first-ever task** | `AddTaskSheet`'s `onCreate` closure, detected as `tasks.isEmpty` before the append | → `.lockedTasks` (dailyLimitMin is **not** touched here — it might already have been customized in Rules) |
| Parent approves everything outstanding | `approveAllPendingReview()` | → `.unlocked`, `timeLeft`/`timePct` reset to full |
| Parent taps the lock button (`LockActionButton`) while unlocked | `headerCard`'s tap handler | → `.locked` |
| Parent taps unlock with tasks still open | → `showUnlockConfirm`, then on confirm | → `.unlocked` |
| Downtime rule ends / gets toggled off | `exitDowntimeIfActive()` | → `.unlocked` |

If you need a new automatic status change, add it at the real event site
(a task action, a rule change) — don't add a background "recompute status"
pass; there isn't one, and introducing one would conflict with the manual
lock/unlock the parent can always do on top of any automatic state.

### `ChildRule` / rules (`TaskData.swift`)

```swift
enum RuleKind { case downtime, custom, screenTimeLimit }
struct ChildRule { id, kind, icon, title, detail: String, on: Bool, downtimeFrom/To }
```

Every `Child` gets two built-in rules seeded at construction via
`TaskStore.rules(dailyLimitMin:)`: Screen Time Limit and Downtime. The
Screen Time Limit rule's `detail` is a **separately-maintained display
string** ("1h per day") — it does not auto-derive from `dailyLimitMin`.
Whenever you change `dailyLimitMin` from code, you must also update
`child.rules[idx].detail` yourself (see `EditDailyScreenTimeLimitSheet`'s
`onSave` in `ScreenProfile.swift` for the pattern).

### Tasks (`TaskData.swift`, `ChildTask`/`TaskStore`)

```swift
enum TaskState { case done, review, pending, overdue, bypass, bypassed }
struct ChildTask { id, title, state, category, description, note,
                    submittedAt, dueLabel, dueDate, photoCount, repeats,
                    hasVoiceNote, redoNote, redoHasVoiceNote }

enum TaskStore {
    private static var cache: [String: [ChildTask]]
    static func tasks(for childId: String) -> [ChildTask]
    static func binding(for childId: String) -> Binding<[ChildTask]>   // live, shared, mutable
    static func rules(dailyLimitMin: Int) -> [ChildRule]
}
```

`TaskStore` has a real per-child cache and a `Binding` accessor — this is
**genuinely shared, live state**, not a snapshot. `ScreenProfile` holds its
task list as `@Binding private var tasks: [ChildTask] = TaskStore.binding(for:
childId)`, so an edit made through `ScreenProfile` is immediately visible to
anything else reading `TaskStore.binding(for:)` for the same id (e.g. a
notification tap opening `TaskReviewDeckView` directly from `ScreenHome`).

`TaskStore.generate(for:)` (the cold-start seed) now always returns `[]` —
every real child starts with no tasks. This used to have per-id branches
seeding a different hand-authored task list per demo child (one per status
being showcased); that content is preserved in git history (see "History"
below), not in the live code.

State transitions: Approve → `.review`/`.bypass` becomes `.done`/`.bypassed`.
Redo → back to `.pending`. Two files assign `.state =`, not one — the same
approve logic is duplicated in both: `TaskReviewDeckView` (the swipeable
per-task queue, `TaskReviewDeck.swift`, approving one at a time — and see
its `unlockIfEverythingResolved()` for why that file also auto-unlocks the
child once the last task is cleared this way) and `ScreenProfile`'s
`approveAllPendingReview()` (bulk "Approve All"). Both must independently
reach the same end state — see `docs/child-status-and-cards.md` §3 for the
full trigger table. `.overdue` is never set programmatically in the
current code — it would need a real due-date-passed check if you want it to
happen automatically for a real task.

### The `familyRefreshTick` pattern

`FamilyStore.children` isn't `@Published`, so a view reading it directly
won't know to re-render when Settings adds/removes a child. The fix used in
both `ScreenHome.swift` and `ScreenSettings.swift`:

```swift
@State private var familyRefreshTick = 0
// ... in body, on the content that reads FamilyStore.children:
.id(familyRefreshTick)
// ... wherever a mutation happens (add/remove child):
familyRefreshTick += 1
```

`.id(x)` is load-bearing here — SwiftUI only knows to rebuild a subtree when
something it actually *reads* changes. A bare `@State` bump that nothing
reads is a no-op (this was an actual bug earlier in this project's history:
the tick was being bumped but never read, so the Family list silently went
stale until some unrelated re-render happened to catch it up). If you add a
new screen that lists `FamilyStore.children`, use this same pattern.

## Two disconnected worlds: parent vs. kid tablet

The kid-side tablet app (`Evlin/Tablet/*`, entered via `TabletRootView`) has
its **own, completely separate mock data model** in `Evlin/Data/TabletData.swift`:

```swift
struct KidChild { id, name, usedMin, limitMin }
struct KidTask { id, title, iconTaskId, due, done, bypassRequested, ... }
enum TabletData { static let child: KidChild; static var tasks: [KidTask] }
```

There is **no bridge** between this and `FamilyStore`/`TaskStore`/`Child`/
`ChildTask` on the parent side — confirmed no cross-references either
direction anywhere in the codebase. A task the kid marks done on their
tablet does not change anything the parent sees, and the parent locking the
phone via `ScreenProfile` does not touch `TabletData.tasks`/the kid's own
`locked` computed property (`doneCount < tasks.count` in
`TabletRootView.swift`). If a request implies "the kid's phone actually
locks when the parent taps lock," that cross-device sync doesn't exist —
building it is a real feature addition (would need a shared data layer or a
backend), not a quick wire-up.

`Evlin/Data/CalendarData.swift` and `Evlin/Data/NotificationsData.swift`
also hardcode the literal id `"liam"` for seeded events/notifications, and
`Evlin/Parent/ScreenChat.swift` does `FamilyStore.child("liam")` directly.
The onboarding-created child deliberately keeps the id `"liam"` (see
`FamilyStore.addOnboardedChild`) so all of these keep working without
changes — if you ever need a different/dynamic child id, you must also fix
these three files, or they'll silently reference a child that isn't there.

## Screen map (parent side)

`Evlin/Parent/ParentRootView.swift` is a plain `TabView` with 5 tabs:

| Tab | File | Notes |
|---|---|---|
| Home | `ScreenHome.swift` | Shows `FamilyStore.children.first`'s `ScreenProfile` inline (not behind a modal) so the tab bar stays visible. Falls back to a "no child yet" placeholder if empty (only reachable if the parent removes their only child in Settings). |
| Calendar | `ScreenCalendar.swift` | Day-timeline view, task/event split, its own "Add Event"/"Add Task" forms via `FormShell` (`AddFormComponents.swift`). |
| Chat | `ScreenChat.swift` | Mocked AI assistant chat. |
| Library | `ScreenLibrary.swift` | Parenting content — articles, and a real illustrated comic ("Weathering the Meltdown") via `ComicReaderView.swift` + `LibraryData.swift`. |
| Settings | `ScreenSettings.swift` | Account, Family (list + "Add a child"), Alerts, Support. Per-child editing via `ChildSettingsSheet`. |

`ScreenProfile.swift` (not a tab itself — what Home shows) is the single
biggest file: header card (avatar, time-left bar, lock/unlock button,
Approve All), Current Tasks list (`TaskRowView`), Active Rules
(`rulesSection`), and every task/rule edit sheet. `TaskReviewDeck.swift`
is the swipeable "review one task at a time" flow opened from a task row or
a notification tap — a hand-rolled horizontal pager (`ScrollView(.horizontal)`
+ `.scrollTargetBehavior(.paging)`), deliberately not `TabView(.page)` (see
its own comment: `TabView.page`'s UICollectionView backing conflicts with
`TaskReviewCard`'s own nested vertical scroll).

## Screen map (kid/tablet side)

`Evlin/Tablet/TabletRootView.swift` — a 3-tab `TabView`: Task
(`ScreenTabletHome.swift`), Calendar (`ScreenTabletCalendar.swift`), Library
(`ScreenTabletLibrary.swift`), plus `TaskDetailView.swift` (photo submission,
bypass request) and `ScreenTabletSettings.swift` (a sheet, not a tab — see
`KidAdaptive.swift`'s iPad-sizing note on why sheets vs. fullScreenCover
matters here). All driven by `TabletData`, independent of the parent side as
described above.

## Design system / shared components

- `Evlin/DesignSystem/Theme.swift` — `EColor`, `Typography`, `Brand` — the
  color/font tokens used everywhere. `EColor.primary`/`.danger`/etc. are
  semantic, not raw hex — prefer them over `Color(hex:)` for anything that
  should track the design system.
- `Evlin/DesignSystem/Components.swift` — `PrimaryButton`, `Card`, `EToggle`,
  and other cross-screen primitives.
- `Evlin/Parent/AddFormComponents.swift` — `FormShell`/`FormField`/
  `FormTextField` — the shared "Cancel top-left, bold title, scrollable
  fields, full-width Save pill" chrome used by every compose sheet (New
  Task, Edit Task, Redo note, Edit Rule, Add Event). If you add a new
  compose flow, build it on `FormShell` rather than a bespoke layout.
- `Evlin/Parent/ParentAdaptive.swift` / `Evlin/Tablet/KidAdaptive.swift` —
  near-identical helpers (`isRegular`, `.of(compact:regular:)`,
  `contentMaxWidth`) driven by `horizontalSizeClass`, used throughout both
  sides to scale up for iPad instead of stretching/shrinking a phone layout.
  Kept as two separate types rather than shared, since parent and kid
  screens hit iPad adaptation independently and at different times.

## Known gaps / things not to assume exist

- **No persistence.** Nothing survives an app relaunch — not onboarding
  completion, not created tasks, not rule edits. If a request implies "this
  should still be there tomorrow," that needs real persistence added first
  (there's no `UserDefaults`/Core Data/SwiftData/backend call anywhere).
- **No push notifications, no real pairing, no real photo capture.**
  `NotificationsData.swift` is a static seeded list; a kid "taking a photo"
  in `TaskDetailView` renders a mock homework-page graphic
  (`MockHomeworkPhoto`), not a real camera capture.
- **No test target.** Verification in this repo happens by building with
  `xcodebuild`, installing/launching with `xcrun simctl`, and screenshotting
  — there's no way to simulate a tap/drag gesture in this environment, so
  interactive states are reached via temporary `ProcessInfo.processInfo
  .environment["EVLIN_DEBUG_*"]`-gated code paths added for one verification
  pass and always fully reverted afterward (`grep -rn "EVLIN_DEBUG" Evlin/`
  should return nothing in any finished state).

## History

The 12-hardcoded-demo-child gallery (one child permanently showing each
status: unlocked, locked, lockedTasks, downtime, reflection-in-progress,
trial-exhausted, needs-protection-setup, all-tasks-submitted, etc.) that
predates this restructure is preserved in git history — see commit `92ee5c8`
("Checkpoint: iPad adaptation, kid/parent UI polish, and bug fixes before
single-child restructure") for the last state before it was retired, if you
ever need to reference how a specific status card used to look.
