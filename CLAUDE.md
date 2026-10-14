# Evlin

A parental-control app where screen time is earned by doing tasks. One iOS
app with two modes chosen at first launch:
- **Parent (iPhone):** tabs are Home, Calendar, Chat, Library, Settings.
- **Kid (iPad or iPhone):** tabs are Task, Library, Calendar.

The backend is FastAPI on Render with Postgres on Supabase and photos on
Cloudflare R2.

Latest state and open items: [`docs/handover-2026-10-03.md`](docs/handover-2026-10-03.md).

## Layout

| Path | What |
|---|---|
| `Evlin/` | SwiftUI app. `Data/` holds the API client, sync, the SwiftData cache and the enforcement state. `Parent/`, `Tablet/` (kid), `Onboarding/`, `DesignSystem/` |
| `evlin-backend/` | FastAPI app (`main.py`), `routers/`, `models.py`, `schemas.py`, `tests/` |
| `evlin-backend/tool_calls/` | Every tool the chat AI can call, one file each, with a README listing them |
| `docs/` | Handovers and architecture notes. Older ones carry a note saying what's out of date |

## Commands

```bash
# backend tests (SQLite in memory, no network)
cd evlin-backend && python3 -m pytest tests/ -q

# add a test child to a parent account to preview the multi-child app, then
# remove it (previews unless --yes; .env's database is normally the live one)
cd evlin-backend && python3 scripts/test_child.py find dashnyamesen@gmail.com
cd evlin-backend && python3 scripts/test_child.py add dashnyamesen@gmail.com --name Mia --yes
cd evlin-backend && python3 scripts/test_child.py remove dashnyamesen@gmail.com --all-test --yes

# iOS: regenerate the project after adding or removing files, then build
xcodegen generate
xcodebuild -project Evlin.xcodeproj -scheme Evlin \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# iOS unit tests (EvlinTests: staying signed in across relaunches and token
# expiry; the network is stubbed). Use a simulator other than the one in use.
xcodebuild test -project Evlin.xcodeproj -scheme Evlin \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EvlinTests
```

Verify parent-side changes on an iPhone simulator and kid-side changes on an
iPad simulator. Screen Time APIs don't work on the Simulator at all.

## Rules that hold the design together

- **The AI never writes.** Its tools (`draft_task`, `draft_event`,
  `ask_follow_up`) pre-fill a card or ask a question. The parent's tap is what
  creates anything. To add a tool, add a module to `tool_calls/`; `chat.py`
  reads only what that package exports.
- **AI features are architecture, not screens.** Don't add UI to inspect AI
  internals (memory, for example) unless asked.
- **The schema change mechanism is `main.py` `_MIGRATIONS`.** It's a list of
  idempotent statements run on every boot; there's no Alembic. Every new model
  or column needs a matching statement there, and an entry in
  `_EXPECTED_COLUMNS`. Tests build from `models.py`, so
  `tests/test_migrations.py` is what catches a missing migration. Postgres-only
  SQL must be checked on a real Postgres.
- **Every approval goes through `routers/occurrences.py` `_review`.**
  That covers the bonus, block resolution, and refusing a double approval.
  Don't add a second path. (A kid's calendar plan is an event, not a task:
  its approval has its own single path, `routers/calendar.py` `_review_plan`.)
- **Live updates are published by a commit hook, not by routes**
  (`live_updates.py`). Reads must not write: a read that writes announces a
  change, which makes the device sync, which reads again. Expiry and similar
  state are computed on read (`blocks.py`), never stored.
- **Apps are Evlin's own catalog rows** (`apps`, `child_apps`), never platform
  identifiers. Blocks point at catalog ids.
- **"Today" and "now" are the child's**, from `children.timezone` via
  `blocks.local_now`, not the server's UTC.
- **Access checks are in the application**, through `access.py`. There's no
  Postgres row-level security. Every child-scoped route must check ownership.

## Removed — don't reintroduce without asking

These were removed deliberately, with their tables dropped:
- courses and YouTube lessons, course tasks
- reflections
- milestones
- the old Library (slide lessons, origami guides). The new Library, below,
  is YouTube video bundles and shares nothing with it
- comics
- voice notes
- the memory screen
- AI-drafted app blocks
- parent and family-wide calendar events: every event belongs to one child
  (`events.child_id` is required, `is_parent_only` is dropped)

The AI does tasks and calendar only. Some migrations in `main.py` mention
these features: those are the drops, and they must stay.

## Library (layout only, for now)

Each child has three bundles: short series of YouTube lessons, one lesson
from each a day, played in `YouTubeEmbedView`. Both tabs (`ScreenLibrary`,
`ScreenTabletLibrary`) run on hand-picked sample data in
`Data/LibrarySampleData.swift`, with progress kept in memory on each device.
No AI decides anything here yet: a dedicated Library Agent, separate from
Chat, is planned and will replace `LibraryStore`'s reads. Don't build it
until the user says the architecture is ready.

Kept on the backend for it, but not called by the app: `youtube_client.py`,
`video_filter.py` (hard filters), `video_curation.py`, `routers/videos.py`,
and the `child_video_profiles` and `video_queue_items` tables. The
Library's settings button does save to `child_video_profiles`.

## Phone database (local-first)

The goal: screens show what's saved on the phone straight away, a tap
changes the screen at once, and the network catches up behind it. Nothing a
parent or kid does is lost to a bad connection or a closed app.

- **One SwiftData store** (`Data/LocalStore.swift`) holds every child (their
  rules and state included), their tasks, today's occurrences, time grants,
  app blocks, policy and calendar events. Launch hydrates **all** children
  and the calendar from it before the network answers.
- **"Today" is live.** `CalendarData.todayYear`, `todayMonth` and `dataDay`
  read the clock. `DayClock` notices midnight and a return to the
  foreground on a new day, moves the calendar onto the new today, and
  syncs.
- **Every write goes through the outbox** (`Data/Outbox.swift`): one
  write = one saved HTTP request (`APIClient.Write`), in a `PendingWrite`
  row, sent in order, retried with backoff while offline or while the
  server errors. Screens apply the change themselves first (optimistic).
  A 404 or 409 on replay means the server already has it, so the write is
  dropped quietly. Any other refusal is dropped and reported through
  `SyncState.writeError`. Don't call `APIClient`'s write methods directly
  from a screen: queue them.
- **Creates carry the phone's id.** A task, event or plan gets its UUID on the
  phone. The server accepts `id` on create and answers a repeat of the same
  create with the existing row, so a retry never duplicates anything.
- **Kid writes against a day the phone made up offline** (an occurrence
  materialized locally) name the task and date instead of an occurrence id.
  The outbox finds the real occurrence when it sends.
- **A sync never overwrites a pending write:** it sends the outbox first and
  only fetches once the outbox is empty. Writes are also mirrored into the
  store as they're queued (task created or deleted, occurrence status), so a
  relaunch before they're sent still shows them.
- **Screens read tasks and the calendar from the database.** `TaskStore` is
  an observed, read-only view of it, rebuilt on every database save
  (`LocalStore.commit`; a sync's writes are one `batch`). A screen never
  edits a copy: an action writes the database (`TaskEdits`, the `mirror…`
  functions) and every screen showing it updates in the same frame. Don't
  keep task or event lists in `@State`.
- **Syncs merge, and redraw only on change.** Store rows are updated in
  place by id, not deleted and re-inserted, and `TaskStore` only assigns
  what changed. There's no full re-sync after each write: the server's live
  update brings the change back.

Not done yet: children (`FamilyStore`, `Child`) are live objects built from
the database, not read from it on every draw; `SyncState.version` redraws
for changes to the family. The server has no "changed since" endpoint, so a
sync still downloads everything and the phone does the merging. Photo uploads
keep their own queue (`TaskDetailView.upload`).

## Gotchas

- `xcodegen generate` rewrites `Evlin.xcodeproj` from `project.yml`. Settings
  changed only in Xcode, such as the bundle id, are lost.
- SourceKit reports false "cannot find type" errors here. Trust `xcodebuild`.
- A shell-exported `GEMINI_API_KEY` shadows `.env`, because `load_dotenv`
  doesn't override.
- `evlin-tables.sql` is an old design file. It isn't the schema, and
  `init_db.py` can't apply it cleanly.
