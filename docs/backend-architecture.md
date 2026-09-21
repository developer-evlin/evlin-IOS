# Evlin backend architecture

A from-scratch orientation to `evlin-backend/`, for an agent (or developer)
with no prior context. Covers the real, currently-deployed system — not the
aspirational one described in `evlin-tables.sql` (see "Schema — what's
actually true" below, read that section before touching the DB). Ends with
a section on Milestones, a goal-tracker feature that's been planned but not
yet built — included here so it's designed against the real architecture
from day one, not bolted on after the fact.

Note: `docs/frontend-architecture.md` predates this backend entirely — it
describes an earlier, fully-mocked prototype ("no backend," "no
persistence," "no real photo capture"). None of that is true any more. Treat
this document as the current source of truth for anything backend-related;
the frontend doc needs a pass of its own at some point, but that's a
separate piece of work from this one.

## What this is

FastAPI (`evlin-backend/main.py`) + SQLAlchemy + Postgres via Supabase +
Cloudflare R2 for file storage, deployed on Render at
`https://evlin-ios.onrender.com`. The iOS app (`Evlin/`) is the only client.
Two roles hit the same API: a parent (Supabase-auth'd) and a kid's paired
device (its own bearer-token scheme, not Supabase auth — see "Auth" below).

## Schema — what's actually true

There are **three** descriptions of the schema in this repo, and they
disagree. Only one of them is real:

1. **`evlin-backend/main.py`'s `_MIGRATIONS` list (lines ~12-86) — this is
   the actual, deployed schema.** A list of idempotent `CREATE TABLE
   IF NOT EXISTS`/`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements,
   run on every app boot via `apply_migrations()`. There is no Alembic, no
   migration-version table, no separate migration-runner — this list *is*
   the deploy mechanism. Adding a column or table means appending a
   statement here.
2. **`evlin-backend/models.py`** — the SQLAlchemy models the app actually
   queries against, kept in sync with #1 by hand.
3. **`evlin-tables.sql`** (repo root) — a **stale, aspirational design
   doc**. It describes tables that don't exist in the live database at all
   (`app.push_outbox`, `app.parent_devices`, `app.reflections` — no
   SQLAlchemy model, never created by any migration) and is missing columns
   #1 has since added (`tasks.due_date`, `tasks.category`,
   `app.device_pairings`, several `events.*` columns). It also has columns
   #1 has since *dropped* (`tasks.points`, `tasks.comic_id`,
   `child_state.last_tripwire_*`, `child_rules.blocked_categories` —
   removed because nothing computed them, per the migration comments right
   above their drop statements). **Never trust `evlin-tables.sql` over
   `main.py`'s migration list** — if you need to know what a table actually
   looks like, read the migration list or `models.py`, not this file.

All tables live in Postgres schema `app.` (e.g. `app.tasks`, not `tasks`).
All primary keys are `uuid`, defaulted client-side by SQLAlchemy
(`uuid.uuid4`), not by a Postgres `gen_random_uuid()` default.

## Core domain models

All in `evlin-backend/models.py`.

### Identity & family

```python
class Parent:      # app.parents — id, email, name, plan ('free'|'pro')
class Child:        # app.children — id, name, birth_year, color_index, activated_at
class ParentChild:  # app.parent_children — composite PK (parent_id, child_id), role
```

**There is no `Family` table.** "Family" is entirely the `ParentChild` join
table — a child can have more than one parent (co-parents). Every
ownership check in this codebase walks this table; nothing denormalizes a
`family_id` onto other rows. If you're adding a new table that needs to be
scoped to a family, scope it by `child_id` (like `Task` does) and resolve
"does this parent own this child" via `ParentChild`, not by inventing a
`family_id` column.

### Auth

```python
class Device:         # app.devices — id, child_id, token_hash, push_token (unused, see below)
class DevicePairing:  # app.device_pairings — code (PK, not uuid), secret_hash, expires_at
```

Two independent auth schemes, both in `routers/auth.py`:
- **Parent**: a Supabase JWT, verified via `supabase.auth.get_user`, then
  mapped to a local `Parent` row (`get_current_parent`).
- **Kid device**: a bearer token, hashed and looked up against
  `Device.token_hash` (`get_current_device`). Pairing happens through
  `DevicePairing` (a short-lived code + secret the parent's app shows and
  the kid's app claims). `PairingCode` also exists in `models.py` but isn't
  referenced by any router — `DevicePairing` is the one actually in use.

A third helper, `assert_child_access` (`access.py`), accepts *either* role
— used by endpoints both a parent and that child's own device can read.

### Tasks

```python
class Task:        # app.tasks — child_id, title, recurrence, due_time/date,
                    #             submission_kind ('none'|'photo'|'voice'|'either'), bucket
class Occurrence:   # app.occurrences — task_id, due_date, status
                    #   ('pending'|'submitted'|'approved'|'rejected'|'expired')
class Submission:   # app.submissions — occurrence_id (NOT NULL), kind ('photo'|'voice'),
                    #                   r2_key, status ('pending'|'uploaded')
```

`Task` rows are recurring definitions; `Occurrence` rows are the
day-specific instances a kid actually acts on. Occurrences are **not**
pre-generated by a cron — `GET /children/{id}/occurrences?target_date=`
lazily materializes any missing occurrence for that date on read
(`_generate_occurrences_for_date`, `routers/occurrences.py`). The backend
itself has no "today only" restriction — `target_date` is a free parameter.
What *is* today-only in practice is the **client**: `APIClient.fetchOccurrences(childId:)`
hardcodes `target_date` to `Date()`, so occurrence *status* is only ever
synced for today anywhere in the app today — the backend would happily
return another date's occurrences if asked.

No gamification columns exist (`tasks.points`/`comic_id` were dropped,
per `main.py`'s migration comments — "nothing computes a tripwire," "no
gamification UI exists"). Don't resurrect points/rewards on `Task`/
`Occurrence` directly — see "Planned: Milestones" below for where that kind
of thing belongs instead.

### Rules & lock state — read this before touching anything here

```python
class ChildRule:   # app.child_rules — daily_limit_minutes, downtime_enabled/start/end, custom_rules (json)
class ChildState:  # app.child_state — manual_lock, task_gate_override
```

These describe the **app's own** displayed lock state and rule
*intentions* — not real Apple Screen Time enforcement. There is no
DeviceActivityMonitor extension, no ManagedSettings extension, and no
`ManagedSettingsStore`/shield-applying code anywhere in this codebase (zero
`import DeviceActivity`/`ManagedSettings` matches, confirmed by direct
search). The only real touchpoint with Apple's Screen Time system is a
one-time `AuthorizationCenter.requestAuthorization` permission prompt in
onboarding. `ChildState.manual_lock`/`task_gate_override` just drive what
the UI *shows* as locked/unlocked; nothing here actually restricts device
usage. Treat `ChildState`/`ChildRule` and `routers/rules.py` as a separate,
sensitive area — a new feature that reads task/occurrence completion and
wants to "unlock" something should very deliberately decide whether it
means the real thing or just this display state, and should not casually
extend these tables or routes.

### Calendar

```python
class Event:          # app.events — child_id (nullable = family-wide), start_at, end_at, category
class EventProposal:   # app.event_proposals — ICS-import conflict review, a different purpose
```

## Routes & routers

`main.py` mounts: `auth`, `tasks`, `occurrences`, `submissions`, `rules`,
`calendar`, `children`, `compliance`, `content`. Each router file is scoped
to one domain; auth/ownership is enforced per-route via the dependencies
above plus manual ownership helpers in `access.py`
(`assert_parent_owns_child`, `get_task_for_parent`,
`get_occurrence_for_parent`, `get_occurrence_for_device_or_parent`). Its own
module docstring explains why these exist: early versions trusted any
signed-in parent to touch any child's data by id alone; these helpers close
that.

**There is no Postgres Row-Level Security anywhere in this codebase** (zero
`CREATE POLICY`/`ENABLE ROW LEVEL SECURITY` statements, confirmed by direct
search) — the DB connection is a single, uniformly-privileged role.
Authorization is 100% application-layer, via the dependencies/helpers
above. If a spec says "RLS," it means "an `access.py`-style ownership check
in the route," not an actual Postgres policy.

## Transactions

No route anywhere uses `db.begin()` or a stored procedure for writes.
The pattern, everywhere: fetch every row you need in Python, mutate them
all, call `db.commit()` once at the end of the request. The clearest
example is `complete_submission` (`routers/submissions.py`) — it flips
`Submission.status` on one row and, in the same function body before one
trailing commit, conditionally flips the parent `Occurrence.status` on a
different row. Mirror this shape for any new atomic cross-table write;
don't introduce `db.begin()`/PL/pgSQL functions for writes — nothing else
here does that (see "Known gaps" for the one place a DB-side function was
*considered* and rejected).

## File uploads (Cloudflare R2)

`storage.py` is a thin, fully generic wrapper: `generate_presigned_upload_url(object_name,
content_type, ...)` / `generate_presigned_download_url(object_name, ...)`,
both boto3-over-S3-API against R2, both return `None` on any failure rather
than raising (a route decides what that means). `storage_configured()`
checks the three `R2_*` env vars are set — **these are per-environment**
(local `.env` vs. Render's own dashboard env vars are separate; a working
local upload doesn't mean the deployed service can upload — `GET /health`
reports `storage_configured` for exactly this reason).

The existing upload flow (`routers/submissions.py`, 3 routes: create /
complete / list) is generic in *shape* but not in *parameterization* — it's
hard-wired to `occurrence_id` (a `NOT NULL` FK on `Submission`) and a
`photo|voice`-only `kind` check constraint. A new feature needing proof
uploads against a different kind of row should call `storage.py` directly
with its own key template and its own upload/complete routes, rather than
trying to bend `Submission`/`occurrence_id` to fit — see "Planned:
Milestones" for a concrete example of this.

Client-side, the matching calls are in `Evlin/Data/APIClient.swift`:
`createSubmission` → `uploadToPresignedURL` (a raw `PUT` straight to R2,
bypassing the backend's own bearer auth entirely — the signed URL itself is
the credential) → `completeSubmission`.

## Real-time / "push notifications"

**No real push notification infrastructure exists anywhere** — no APNs, no
Firebase, no `aioapns`, nothing. `Device.push_token` is a column that
exists but is never read or written by any route. `evlin-tables.sql`
describes `app.push_outbox`/`app.parent_devices` tables for exactly this
purpose, but neither has a SQLAlchemy model nor is created by any
migration — designed, never built.

What the app actually uses for "real-time" today is **polling**:
`AppSync.syncBackendData()` (`Evlin/Data/AppSync.swift`) runs on app
foreground and after every write (`BackendWrite.run`), and the kid's own
screen (`TabletRootView.swift`) runs a hard 10-second poll loop the entire
time it's open. Any feature wanting "the other side sees this within a few
seconds" today gets that from this poll loop, not from push — which is a
real, working guarantee (10s is well inside "a few seconds"), just not one
that scales as a general-purpose push replacement for a lot of chatty
features simultaneously.

## Known gaps / debt

- **No Alembic / real migration tool.** `main.py`'s `_MIGRATIONS` list is
  the entire mechanism. It works because every statement is idempotent and
  additive; there's no rollback story.
- **`evlin-tables.sql` is stale and actively misleading.** It should
  probably be deleted or very clearly marked as historical — as-is, it's
  the first thing a new reader finds and it's wrong.
- **No RLS**, by design (see above) — app-layer checks only. Fine as
  long as every new route that touches child-scoped data goes through
  `access.py`-style helpers; easy to reintroduce the exact bug those
  helpers were built to fix if a new route skips them.
- **No push notifications.** Polling works today; a feature that needs true
  push (not just "the other side polls it eventually") is a real,
  standalone infrastructure project — APNs cert/key setup, a working
  device-push-token table actually wired into SQLAlchemy, a send path, a
  retry queue — not something to build as a side effect of an unrelated
  feature.
- **`evlin-backend/tests/` runs on SQLite** (`conftest.py` attaches an
  in-memory SQLite DB as schema `app`), which has no PL/pgSQL and no
  `generate_series`. Any DB-side procedural logic (a stored function doing
  a day-by-day streak walk, for instance) is untestable through this
  harness as it exists today — prefer a plain Python function the route
  calls and a unit test calls directly, and reserve SQL for logic simple
  enough to be a one-line aggregate query.
- **Occurrence status is today-only, client-side**, as noted above under
  Tasks — the backend supports any date, `fetchOccurrences` just never
  asks for one.

## Planned: Milestones (goal tracker) — not yet built

A parent sets up a longer-running goal for a kid (read every day for 60
days; a multi-step bedtime routine; 3 A's this term) with a prize at the
end; the kid submits proof, the parent approves, both sides see
progress/streaks/badges. Designed to slot into everything above without
deviating from any established pattern:

- **Scoping**: `app.milestones` keyed by `child_id` + `created_by` (parent
  id) — no `family_id`, matching "there is no Family table" above.
  `app.milestone_steps` (for multi-step goals) and `app.milestone_entries`
  (for daily/count goals) hang off it by `milestone_id`.
- **Schema delivery**: new `CREATE TABLE IF NOT EXISTS` statements appended
  to `main.py`'s `_MIGRATIONS` — the one real mechanism, not a new one.
- **Auth**: new `get_milestone_for_parent`/`get_milestone_for_device_or_parent`
  helpers in `access.py`, mirroring `get_task_for_parent`/
  `get_occurrence_for_device_or_parent` exactly. No RLS.
- **Transactions**: plain FastAPI routes, mutate-then-commit-once — e.g.
  approving a step sets that step `approved` *and* the next step `active`
  in the same request/commit, same shape as `complete_submission`.
- **Uploads**: does **not** reuse `Submission`/`occurrence_id` — two small
  new routes call `storage.py`'s presigned-URL functions directly under a
  `milestones/{child_id}/{milestone_id}/...` key, writing the resulting key
  straight into `milestone_entries.proof_url`/`milestone_steps.proof_url`.
- **Real-time**: piggybacks on the existing poll loop (`AppSync`/
  `TabletRootView`'s 10s loop) — no new push infrastructure.
- **Streak/rest-day math**: a plain Python function (`_compute_daily_progress`),
  not a Postgres function, specifically because of the SQLite-test-harness
  gap noted above — it needs to be unit-testable.
- **Stays out of the enforcement boundary entirely**: never touches
  `ChildState`/`ChildRule`/`routers/rules.py`, never calls
  `updateChildState`, defines its own model/view types rather than reusing
  `ChildTask`/`TaskStore` (which would silently inherit
  `TaskReviewDeckView`'s task-gate-unlock side effect).

A full parent+kid UI plan (screen list, component reuse against the
existing design system, a 4th kid tab, moving parent Settings behind a
header gear to make room for a Milestones tab) exists as a separate,
already-approved-pending plan — this section only covers how the backend
piece fits the architecture above. Ping before starting if you don't have
that fuller plan in hand.
