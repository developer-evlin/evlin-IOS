# Evlin frontend component & Profile-screen guide

Companion to `docs/frontend-architecture.md` (read that first for the overall
app/data-flow picture — mode switching, onboarding, `FamilyStore`/`TaskStore`,
the two-disconnected-worlds split). This doc has two parts: (1) a walkthrough
of how each major frontend component/screen actually works, and (2) a
section-by-section breakdown of the Profile screen specifically (`Evlin/Parent/ScreenProfile.swift`), since it's the single biggest and most stateful
screen in the app.

## Part 1 — How each component works

### App shell
- **`EvlinApp.swift`** — `@main`, just hosts `RootView`. No app-level state.
- **`RootView.swift`** — owns `mode` (parent/tablet/nil), `parentOnboarded`/
  `childOnboarded` (session-only bools, not persisted), and `showSplash`.
  Everything downstream is reached by switching on these three values. This
  is the only place that decides "which of the two apps" is showing.

### Onboarding
- **`OnboardingV2Coordinator.swift`** — a single `@State private var step:
  OnboardingV2Step` enum drives a `switch` that renders one step view at a
  time; each step view is handed `onContinue`/`onBack` closures that just
  reassign `step`. No `NavigationStack` — this is a hand-rolled linear
  wizard, which is why back/forward is just closures instead of pop/push.
- **`OnboardingV2ParentSteps.swift` / `OnboardingV2ChildSteps.swift`** — the
  actual step content (sign-in, profile, screen-time consent, etc.), one
  `struct` per step. All "network" calls in here (`pairWithKidCode`, "waiting
  for kid") are `Task.sleep` stand-ins, not real requests.
- **`OnboardingV2Components.swift` / `OnboardingV2Theme.swift`** — shared
  chrome (`OnboardingV2ScreenContainer` for consistent padding/back-button/
  progress-dots, buttons, segmented controls) and the color/spacing tokens
  specific to onboarding.

### Parent-side screens (`Evlin/Parent/`)
- **`ParentRootView.swift`** — a plain 5-tab `TabView`. No shared state
  beyond `onSwitchMode` passed down to Settings.
- **`ScreenHome.swift`** — resolves `FamilyStore.children.first` and renders
  that child's `ScreenProfile` inline (see Part 2). Also owns the
  notification-tap fullScreenCovers (`directReview`, `openChildId`) and the
  `familyRefreshTick` re-render trick (see architecture doc).
- **`ScreenProfile.swift`** — see Part 2 in full.
- **`ScreenCalendar.swift`** — a day-timeline view mixing tasks and events
  from `CalendarData.swift`; "Add Event"/"Add Task" are `FormShell`-based
  sheets (see below).
- **`ScreenChat.swift`** — a mocked AI-assistant chat. User messages get a
  canned/keyword-matched reply; some replies render actionable "cards." Only
  the **block-an-app** card actually writes real data — it appends a
  `.custom` `ChildRule` straight onto `FamilyStore.child("liam").rules`
  (`ScreenChat.swift:1088`), bypassing `rulesSection`'s `EditRuleSheet`
  entirely (see `docs/child-status-and-cards.md` §4 for why that matters —
  there's no shared rule-creation function, this is a second, independent
  call site). The **"Add a task"** card, despite pre-filling from the
  parent's message text, is cosmetic only — `handleAddTask`
  (`ScreenChat.swift:1098`) just posts a confirmation chat message; it never
  touches `TaskStore` at all, so tapping it does not actually create a task
  anywhere the rest of the app can see.
- **`ScreenLibrary.swift`** — static parenting content (articles) from
  `LibraryData.swift`; no user-generated state.
- **`ScreenSettings.swift`** — Account / Family / Alerts / Support. The
  "Family" section is the only place besides onboarding that can create a
  child (`FamilyStore.addOnboardedChild`) or remove one
  (`FamilyStore.removeChild`) — both bump `familyRefreshTick` so Home and
  Settings itself stay in sync.
- **`TaskReviewDeck.swift`** — a hand-rolled swipeable horizontal pager
  (`ScrollView(.horizontal) + .scrollTargetBehavior(.paging)`, deliberately
  not `TabView(.page)` — see its own comment on why) for reviewing one
  submitted task at a time: Approve → `.review`/`.bypass` becomes
  `.done`/`.bypassed`; Redo → back to `.pending`. **Not** the only file that
  does this, though — `ScreenProfile`'s `approveAllPendingReview()` (bulk
  "Approve All") duplicates the same `.review`/`.bypass` → `.done`/
  `.bypassed` transition independently. See
  `docs/child-status-and-cards.md` §3 for the full, verified list of every
  place either file changes task state or child status.
- **`AddFormComponents.swift`** — `FormShell`/`FormField`/`FormTextField`,
  the shared "Cancel top-left, bold title, scrollable fields, full-width Save
  pill" chrome. Every compose sheet in the app (New Task, Edit Task, Redo
  note, Edit Rule, Add Event) is built on this rather than a bespoke layout —
  reuse it for any new compose flow.
- **`ParentAdaptive.swift`** — `isRegular`/`.of(compact:regular:)`/
  `contentMaxWidth` helpers keyed off `horizontalSizeClass`, used throughout
  parent screens to scale up for iPad instead of stretching a phone layout.

### Kid/tablet-side screens (`Evlin/Tablet/`)
- **`TabletRootView.swift`** — a 3-tab `TabView` (Task/Calendar/Library) plus
  `ScreenTabletSettings` as a sheet (not a tab). Entirely separate data
  (`TabletData.swift`'s `KidChild`/`KidTask`) — no cross-references to
  `FamilyStore`/`TaskStore` anywhere (see architecture doc's "Two
  disconnected worlds").
- **`ScreenTabletHome.swift`** — the kid's own task list + lock state,
  computed locally as `doneCount < tasks.count`.
- **`TaskDetailView.swift`** — photo submission (a mock graphic,
  `MockHomeworkPhoto`, not a real camera capture) and bypass-request UI.
- **`KidAdaptive.swift`** — the kid-side equivalent of `ParentAdaptive`, kept
  as a separate type deliberately (parent/kid hit iPad adaptation
  independently).

### Design system (`Evlin/DesignSystem/`)
- **`Theme.swift`** — `EColor` (semantic colors — `.primary`, `.danger`,
  `.surface`, etc.), `Typography` (the one place font sizes/weights are
  resolved), `Brand` (a couple of fixed brand colors used outside the
  semantic palette, e.g. `Brand.ink` for the FAB). Prefer `EColor.*` over
  `Color(hex:)` for anything that should track the design system.
- **`Components.swift`** — cross-screen primitives: `PrimaryButton`, `Card`
  (the rounded-white-surface wrapper used by nearly every section on every
  screen), `EToggle` (custom-styled switch), `SectionHead`.

### Data layer (`Evlin/Data/`) — see the architecture doc for full detail
- **`FamilyData.swift`** — `Child` (an `ObservableObject`, one per real kid)
  and `FamilyStore` (the plain static array holding all `Child`s).
- **`TaskData.swift`** — `ChildTask`/`ChildRule` and `TaskStore` (the
  per-child task cache + `Binding` accessor that makes tasks genuinely
  shared/live state across every screen that reads them).
- **`CalendarData.swift` / `LibraryData.swift` / `NotificationsData.swift` /
  `AppCatalogData.swift` / `TabletData.swift`** — static or lightly-mutable
  seed data for their respective screens, each independent of the others.

## Part 2 — Profile screen, section by section

`ScreenProfile` (`Evlin/Parent/ScreenProfile.swift`) is what Home shows for
the one child. Its `body` is a `ScrollView` stacking three sections, plus a
FAB and a pile of conditional overlay cards layered on top via `.overlay`/
`.sheet`/`.fullScreenCover`. Reading order in the file: `body` (line 125) →
`approvalBanner` (332) → `headerCard` (398) → `tasksSection`/
`reflectionSummaryCard` (513/531) → `rulesSection` (613) → everything below
line 707 is a separate, smaller `struct` used by one of those sections.

### 1. `headerCard` — identity + the one primary action
The avatar circle, child's name, and a **status line** that's one of four
mutually-exclusive states:
- **Reflection active** → "Under Reflection" label (no time bar — the
  `reflectionSummaryCard` below takes over the whole screen in this state).
- **Unlocked + screen time limit turned off** → "Unlimited screen time
  today" + a note that the limit reapplies tomorrow.
- **Unlocked (normal)** → "`X` left today" + a `SegmentedTimeBar` (30-minute
  blocks, same visual language used elsewhere in the app for time-left).
- **Downtime** → "Downtime" + "Until `X` tomorrow", no controls (downtime is
  a schedule owned by the Downtime rule, not something this header controls
  directly — see `rulesSection`).
- **Locked / lockedTasks (the `else` branch)** → "Locked" or "Locked ·
  `done`/`total` tasks".

Below that, exactly one primary action button, chosen by a priority order
that matters:
1. If every outstanding task is already submitted (`allTasksAwaitingReview`)
   → **Approve All** button (a plain tap — approving is the "safe" direction,
   unlike locking/unlocking, so it doesn't need a confirm step).
2. Otherwise (and not downtime/reflection) → **`LockActionButton`**, a
   slide-to-confirm-style tap target whose behavior branches on current
   state: unlocked → lock immediately (banks whatever time was left, doesn't
   touch `timeLeft`/`timePct`); locked with open tasks → `showUnlockConfirm`;
   locked with tasks done but banked time left → unlock immediately; locked
   with tasks done and no time left → `showGrantTimeSheet` (ask "how much,"
   not just "yes/no").

### 2. `tasksSection` **or** `reflectionSummaryCard` (mutually exclusive)
- **`tasksSection`** (the normal case) — "Current Tasks" header, then a
  `TaskRowView` per task due today (`isDueToday`), each tappable to open
  `TaskReviewDeckView` starting at that task's real index in `tasks` (not its
  position among just today's visible rows — this distinction is called out
  in the code because getting it wrong silently opens the wrong task).
- **`reflectionSummaryCard`** (shown instead, whenever `child.reflection !=
  nil`) — a self-contained mini-flow: the 3-step reflection process, the
  kid's submitted written answer (once present), and Approve/Request-redo
  actions on it, plus a "Cancel reflection" escape hatch that clears
  `child.reflection` entirely.

### 3. `rulesSection` — expandable list of `ChildRule`s
A collapsible `Card` ("Active Rules" + an `activeRulesCount/total` pill).
Each row: icon + title/detail, an `EToggle`, and an edit pencil. Two things
worth knowing:
- The **Screen Time Limit** rule is built-in and can't be deleted — tapping
  its row or pencil opens `EditDailyScreenTimeLimitSheet` instead of the
  generic rule editor, and turning it off requires confirming via
  `ScreenTimeOffConfirmCard` first (it's removing a core protection, not
  just pausing a rule parents authored themselves).
- Turning the **Downtime** rule off calls `exitDowntimeIfActive()`, which is
  the only way downtime status ends besides its own schedule elapsing.
- Every other rule opens the generic `EditRuleSheet` (with a Delete option).

### 4. The FAB
A single "+" pinned via `.safeAreaInset(edge: .bottom)` (not a `ZStack` with
guessed padding, so it can never overlap the last row of content). Always
opens `AddTaskSheet` — there's no longer a menu here (rules, including
downtime, are created from chat instead).

### 5. Overlay cards (conditionally shown, one at a time in practice)
All styled the same way — a floating card over a dimmed scrim, not a native
`.alert`/`.sheet` — so they read as one consistent "confirm moment" language
across the app:
- **`approvalBanner`** — shown when `child.parentApprovalStatus == .pending`
  (the kid tapped "Parent controls" on their tablet). Approving here is the
  *only* way to clear that pending state; it triggers
  `ParentApprovalVerifyingOverlay` (a brief "verifying it's you" beat) before
  actually flipping the status.
- **`UnlockConfirmCard`** — the "are you sure, `X` tasks still open" gate
  before a manual unlock with outstanding work.
- **`GrantExtraTimeSheet`** — asks for a specific extra-time amount when
  tasks are done but the daily allowance is exhausted.
- **`ScreenTimeOffConfirmCard`** — confirms turning off the built-in Screen
  Time Limit rule.
- **`TrialExhaustedPopupCard`** / **`ProtectionSetupNeededCard`** — nudge
  popups triggered once on `.task` at screen appearance
  (`child.trialExhausted` / `child.needsProtectionSetup`), not tied live to
  those flags afterward (so dismissing with "Not now" doesn't instantly
  reappear from an unrelated re-render).

### Sheets / full-screen covers
- **`TaskReviewDeckView`** (`.fullScreenCover`) — opened via
  `reviewStartIndex`, the swipeable per-task review queue.
- **`AddTaskSheet`** (`.sheet`) — new-task form. Its `onCreate` closure is
  also where the **first-task → `.lockedTasks`** transition happens (see
  `docs/frontend-architecture.md`'s "Status model" table) — this is the one
  place outside `rulesSection`'s two edit sheets where `ScreenProfile`
  mutates something other than its own local `@State`.

## Where to look next
For *why* the data model is shaped this way (single child, event-driven
status, no persistence, the parent/kid split), read
`docs/frontend-architecture.md` — this doc is intentionally just the
component/screen tour, not the data-flow rationale.
