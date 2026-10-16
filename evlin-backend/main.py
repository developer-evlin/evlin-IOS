from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy.orm import Session
from database import get_db
from routers import auth, tasks, occurrences, submissions, rules, calendar, children, compliance, time_grants, chat, app_blocks, live, apps, policy, videos
from routers.auth import limiter
from storage import storage_configured
import app_catalog
import live_updates

app = FastAPI(title="Evlin Backend API", description="API for the Evlin iOS app")

# M-5: Explicit CORS policy — this is a mobile-only backend, so allow_origins
# is empty. The middleware is present so any future web surface (admin dash,
# web app) must consciously add itself here rather than opening everything.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[],         # No browser origins permitted by default
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# H-1: Attach the rate-limiter and its 429-handler to the app.
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)


# Additive, idempotent schema updates for columns added after the original
# evlin-tables.sql (see models.py). Safe to run on every boot.
_MIGRATIONS = [
    "ALTER TABLE app.parents ADD COLUMN IF NOT EXISTS name text",
    "ALTER TABLE app.tasks ADD COLUMN IF NOT EXISTS due_date date",
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS category text",
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS note text",
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS recurrence text NOT NULL DEFAULT 'none'",
    "ALTER TABLE app.child_rules ADD COLUMN IF NOT EXISTS daily_limit_enabled boolean NOT NULL DEFAULT true",
    "ALTER TABLE app.child_rules ADD COLUMN IF NOT EXISTS custom_rules jsonb NOT NULL DEFAULT '[]'::jsonb",
    "ALTER TABLE app.tasks ADD COLUMN IF NOT EXISTS category text",
    # The original schema's tasks.recurrence check only allowed the literal
    # words 'daily'/'weekly'/'none' — the app's day-picker stores a
    # comma-joined weekday list instead (e.g. "mon,wed,fri"), which the old
    # constraint rejected outright on every write that used it. Drop
    # whichever check constraint is actually on that column (its exact
    # auto-generated name isn't something a plain ADD COLUMN can rely on)
    # and replace it with one that accepts both.
    """DO $$
    DECLARE r record;
    BEGIN
        FOR r IN
            SELECT con.conname FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            WHERE nsp.nspname = 'app' AND rel.relname = 'tasks' AND con.contype = 'c'
              AND pg_get_constraintdef(con.oid) ILIKE '%recurrence%'
        LOOP
            EXECUTE format('ALTER TABLE app.tasks DROP CONSTRAINT %I', r.conname);
        END LOOP;
    END $$""",
    """DO $$
    BEGIN
        ALTER TABLE app.tasks ADD CONSTRAINT tasks_recurrence_or_weekdays_check
            CHECK (recurrence IN ('daily','weekly','none')
                   OR recurrence ~ '^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun)){0,6}$');
    EXCEPTION WHEN duplicate_object THEN NULL;
    END $$""",
    # Dropping columns the app never reads or writes — see the schema audit:
    # tasks/occurrences.points (no gamification UI exists), tasks.comic_id
    # (the comics/rewards feature was never built — nothing can even set
    # this over the API), child_state.last_tripwire_* (nothing computes a
    # tripwire), child_rules.blocked_categories (the original SQL's own
    # comment called it "intent only"), and child_rules.bedtime_* (decoded
    # by the app, then never consulted — a dead duplicate of Downtime).
    "ALTER TABLE app.tasks DROP COLUMN IF EXISTS points",
    "ALTER TABLE app.tasks DROP COLUMN IF EXISTS comic_id",
    "ALTER TABLE app.occurrences DROP COLUMN IF EXISTS points",
    "ALTER TABLE app.child_state DROP COLUMN IF EXISTS last_tripwire_minutes",
    "ALTER TABLE app.child_state DROP COLUMN IF EXISTS last_tripwire_at",
    "ALTER TABLE app.child_rules DROP COLUMN IF EXISTS blocked_categories",
    "ALTER TABLE app.child_rules DROP COLUMN IF EXISTS bedtime_enabled",
    "ALTER TABLE app.child_rules DROP COLUMN IF EXISTS bedtime_start",
    "ALTER TABLE app.child_rules DROP COLUMN IF EXISTS bedtime_end",
    # created_at on these four: never decoded by the app (its Codable
    # structs for child/parent/occurrence/event don't declare it) and
    # nothing server-side reads it either. tasks.created_at is kept — it's
    # the fallback anchor date task_applies_on() (and the iOS mirror of it,
    # CalendarSync) use for any task saved with no due date, which is the
    # common path when "more options" isn't opened.
    "ALTER TABLE app.parents DROP COLUMN IF EXISTS created_at",
    "ALTER TABLE app.children DROP COLUMN IF EXISTS created_at",
    "ALTER TABLE app.occurrences DROP COLUMN IF EXISTS created_at",
    "ALTER TABLE app.events DROP COLUMN IF EXISTS created_at",
    # Reserved for a future kid-side per-task icon — see models.py.
    "ALTER TABLE app.tasks ADD COLUMN IF NOT EXISTS icon text",
    """CREATE TABLE IF NOT EXISTS app.device_pairings (
        code text PRIMARY KEY,
        secret_hash text NOT NULL,
        child_name text,
        platform text NOT NULL DEFAULT 'ios',
        child_id uuid REFERENCES app.children(id) ON DELETE CASCADE,
        expires_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
    # Flexible screen-time pool: an append-only ledger, not a mutable
    # balance — see models.py's TimeGrant for why. bonus_minutes on tasks
    # is what a task grants once its occurrence is approved.
    "ALTER TABLE app.tasks ADD COLUMN IF NOT EXISTS bonus_minutes integer NOT NULL DEFAULT 0",
    """CREATE TABLE IF NOT EXISTS app.time_grants (
        id uuid PRIMARY KEY,
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        minutes integer NOT NULL,
        source text NOT NULL,
        reason text,
        granted_by_parent_id uuid REFERENCES app.parents(id),
        source_ref_id uuid,
        credited_date date NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
    "CREATE INDEX IF NOT EXISTS time_grants_child_date_idx ON app.time_grants(child_id, credited_date)",
    # A5: AI-driven changes and a calendar-style weekly schedule — see the
    # plan doc. All additive; NULL/'parent' defaults keep every existing
    # row's meaning unchanged.
    "ALTER TABLE app.child_rules ADD COLUMN IF NOT EXISTS weekly_schedule jsonb",
    "ALTER TABLE app.tasks ADD COLUMN IF NOT EXISTS created_by text NOT NULL DEFAULT 'parent'",
    "ALTER TABLE app.time_grants ADD COLUMN IF NOT EXISTS created_by text NOT NULL DEFAULT 'parent'",
    # Phase C: real Chat AI — one running conversation per child.
    """CREATE TABLE IF NOT EXISTS app.chat_messages (
        id uuid PRIMARY KEY,
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        parent_id uuid REFERENCES app.parents(id),
        role text NOT NULL,
        text text NOT NULL,
        tool_call text,
        tool_args jsonb,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
    "CREATE INDEX IF NOT EXISTS chat_messages_child_id_idx ON app.chat_messages(child_id, created_at)",
    # Courses (and the course tasks, reflections and milestones built on
    # them) were removed. A task that was completed by finishing a course
    # becomes an ordinary task first: its course is dropped below, and a
    # course task with no course could never be handed in.
    "UPDATE app.tasks SET submission_kind = 'none' WHERE submission_kind = 'course'",
    # Voice notes were removed too: a task that took a photo or a voice note
    # now takes a photo; one that took only a voice note takes nothing. Old
    # voice submissions stay as history (app.submissions still allows them).
    "UPDATE app.tasks SET submission_kind = 'photo' WHERE submission_kind = 'either'",
    "UPDATE app.tasks SET submission_kind = 'none' WHERE submission_kind = 'voice'",
    # A recording's length — nothing a photo has.
    "ALTER TABLE app.submissions DROP COLUMN IF EXISTS duration_seconds",
    # submission_kind's allowed values, rebuilt every boot. Introspect-then-
    # replace, the same shape as the recurrence constraint above, because the
    # constraint's auto-generated name can't be relied on.
    """DO $$
    DECLARE r record;
    BEGIN
        FOR r IN
            SELECT con.conname FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
            WHERE nsp.nspname = 'app' AND rel.relname = 'tasks' AND con.contype = 'c'
              AND pg_get_constraintdef(con.oid) ILIKE '%submission_kind%'
        LOOP
            EXECUTE format('ALTER TABLE app.tasks DROP CONSTRAINT %I', r.conname);
        END LOOP;
    END $$""",
    """DO $$
    BEGIN
        ALTER TABLE app.tasks ADD CONSTRAINT tasks_submission_kind_check
            CHECK (submission_kind IN ('none','photo'));
    EXCEPTION WHEN duplicate_object THEN NULL;
    END $$""",
    # The removed features' storage, dropped for good. Columns referencing
    # the tables first, then tables in foreign-key order (milestones and
    # reflections point at course_assignments, which points at courses).
    # reflections_legacy was the original schema's never-used reflections
    # table, renamed aside when the real one arrived. IF EXISTS throughout,
    # so this is a no-op on every boot after the first.
    "ALTER TABLE app.tasks DROP COLUMN IF EXISTS course_assignment_id",
    "ALTER TABLE app.tasks DROP COLUMN IF EXISTS milestone_id",
    "DROP TABLE IF EXISTS app.reflections",
    "DROP TABLE IF EXISTS app.reflections_legacy",
    "DROP TABLE IF EXISTS app.milestones",
    "DROP TABLE IF EXISTS app.course_item_progress",
    "DROP TABLE IF EXISTS app.course_assignments",
    "DROP TABLE IF EXISTS app.course_items",
    "DROP TABLE IF EXISTS app.courses",
    # The comics and slide-lesson library was removed. These tables were
    # created by the original evlin-tables.sql and never written to (empty
    # in production when this went in).
    "DROP TABLE IF EXISTS app.lesson_slides",
    "DROP TABLE IF EXISTS app.slide_lessons",
    "DROP TABLE IF EXISTS app.comic_panels",
    "DROP TABLE IF EXISTS app.comic_guides",
    "DROP TABLE IF EXISTS content.comics",
    # Structured app blocks, replacing the free-text custom_rules sentence
    # for anything that needs to resolve itself — see models.py's AppBlock.
    """CREATE TABLE IF NOT EXISTS app.app_blocks (
        id uuid PRIMARY KEY,
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        app_name text NOT NULL,
        app_bundle_id text,
        block_type text NOT NULL,
        duration_minutes integer,
        until_task_id uuid REFERENCES app.tasks(id) ON DELETE SET NULL,
        resolved boolean NOT NULL DEFAULT false,
        created_by text NOT NULL DEFAULT 'parent',
        created_at timestamptz NOT NULL DEFAULT now(),
        resolved_at timestamptz
    )""",
    "CREATE INDEX IF NOT EXISTS app_blocks_child_active_idx ON app.app_blocks(child_id, resolved)",
    # Real chat threads. The history sidebar was always designed around
    # separate named conversations; the backend only had one continuous
    # transcript per child, so that UI ran on mock rows and could never
    # really rename, delete or search anything.
    """CREATE TABLE IF NOT EXISTS app.chat_conversations (
        id uuid PRIMARY KEY,
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        parent_id uuid REFERENCES app.parents(id) ON DELETE SET NULL,
        title text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
    )""",
    """CREATE INDEX IF NOT EXISTS chat_conversations_child_idx
        ON app.chat_conversations(child_id, updated_at DESC)""",
    """ALTER TABLE app.chat_messages ADD COLUMN IF NOT EXISTS conversation_id uuid
        REFERENCES app.chat_conversations(id) ON DELETE CASCADE""",
    """CREATE INDEX IF NOT EXISTS chat_messages_conversation_idx
        ON app.chat_messages(conversation_id, created_at)""",
    # Which assistant a message belongs to: the main chat or the YouTube
    # agent, which runs inside the same thread with its own short memory.
    "ALTER TABLE app.chat_messages ADD COLUMN IF NOT EXISTS agent text NOT NULL DEFAULT 'chat'",
    # Backfill: every message written before threading existed gets grouped
    # into one conversation per child, so nothing is orphaned or disappears
    # from the UI. One statement rather than an insert plus a title-matched
    # update, so it's atomic and can't half-apply; a rerun finds no NULL
    # rows and does nothing.
    # What the assistant is allowed to remember between conversations. See
    # models.py's ChildMemory for why these are readable rows rather than
    # embeddings.
    """CREATE TABLE IF NOT EXISTS app.child_memory (
        id uuid PRIMARY KEY,
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        fact text NOT NULL,
        category text,
        source_message_id uuid REFERENCES app.chat_messages(id) ON DELETE SET NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        archived_at timestamptz
    )""",
    """CREATE INDEX IF NOT EXISTS child_memory_child_idx
        ON app.child_memory(child_id, archived_at)""",
    """WITH new_convs AS (
        INSERT INTO app.chat_conversations (id, child_id, title, created_at, updated_at)
        SELECT gen_random_uuid(), child_id, 'Earlier messages',
               MIN(created_at), MAX(created_at)
        FROM app.chat_messages
        WHERE conversation_id IS NULL
        GROUP BY child_id
        RETURNING id, child_id
    )
    UPDATE app.chat_messages m
    SET conversation_id = n.id
    FROM new_convs n
    WHERE m.child_id = n.child_id AND m.conversation_id IS NULL""",
    # Apps get Evlin's own identity — see app_catalog.py. The catalog is
    # global; child_apps is each child's lockable list.
    "ALTER TABLE app.children ADD COLUMN IF NOT EXISTS timezone text",
    """CREATE TABLE IF NOT EXISTS app.apps (
        id uuid PRIMARY KEY,
        name text NOT NULL,
        aliases jsonb NOT NULL DEFAULT '[]',
        category text,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
    "CREATE UNIQUE INDEX IF NOT EXISTS apps_name_uidx ON app.apps (lower(name))",
    app_catalog.seed_sql(),
    """CREATE TABLE IF NOT EXISTS app.child_apps (
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        app_id uuid NOT NULL REFERENCES app.apps(id) ON DELETE CASCADE,
        added_by text NOT NULL DEFAULT 'parent',
        created_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (child_id, app_id)
    )""",
    # Blocks point at catalog apps and come in four kinds — see blocks.py.
    "ALTER TABLE app.app_blocks ADD COLUMN IF NOT EXISTS app_id uuid REFERENCES app.apps(id) ON DELETE SET NULL",
    "ALTER TABLE app.app_blocks ADD COLUMN IF NOT EXISTS ends_at timestamptz",
    "ALTER TABLE app.app_blocks ADD COLUMN IF NOT EXISTS schedule_days text",
    "ALTER TABLE app.app_blocks ADD COLUMN IF NOT EXISTS schedule_start time",
    "ALTER TABLE app.app_blocks ADD COLUMN IF NOT EXISTS schedule_end time",
    "ALTER TABLE app.app_blocks ADD COLUMN IF NOT EXISTS resolved_reason text",
    # Rows written before the catalog: find their app by name or alias, and
    # fix a duration block's end the way new ones get it. Both only touch
    # rows still missing the value, so a rerun changes nothing.
    """UPDATE app.app_blocks b SET app_id = a.id
        FROM app.apps a
        WHERE b.app_id IS NULL
          AND (lower(a.name) = lower(b.app_name)
               OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(a.aliases::jsonb) al
                          WHERE lower(al) = lower(b.app_name)))""",
    """UPDATE app.app_blocks SET ends_at = created_at + make_interval(mins => duration_minutes)
        WHERE block_type = 'duration' AND ends_at IS NULL AND duration_minutes IS NOT NULL""",
    # Evlin keeps the children's calendars only: no parent events, no
    # family-wide ones. Every event gets a child, in this order, each step a
    # no-op on reruns:
    # 1. The parent's own events go (only while the column that marks them
    #    still exists).
    """DO $$
    BEGIN
        IF EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'app' AND table_name = 'events' AND column_name = 'is_parent_only') THEN
            DELETE FROM app.events WHERE child_id IS NULL AND is_parent_only;
        END IF;
    END $$""",
    # 2. Family-wide events have no owner column, so the family can't be
    #    traced. With exactly one child in the whole database they can only
    #    be that child's, and move there; otherwise step 3 removes them.
    """UPDATE app.events SET child_id = (SELECT id FROM app.children)
        WHERE child_id IS NULL AND (SELECT count(*) FROM app.children) = 1""",
    "DELETE FROM app.events WHERE child_id IS NULL",
    "ALTER TABLE app.events DROP COLUMN IF EXISTS is_parent_only",
    "ALTER TABLE app.events ALTER COLUMN child_id SET NOT NULL",
    # Today's videos: a parent-approved list per child per day, filtered by
    # the child's video profile. Not the removed courses — no shared course
    # content, no lessons; see models.py's VideoQueueItem.
    """CREATE TABLE IF NOT EXISTS app.child_video_profiles (
        child_id uuid PRIMARY KEY REFERENCES app.children(id) ON DELETE CASCADE,
        allowed_categories jsonb NOT NULL DEFAULT '[]',
        blocked_keywords jsonb NOT NULL DEFAULT '[]',
        allowed_channels jsonb NOT NULL DEFAULT '[]',
        blocked_channels jsonb NOT NULL DEFAULT '[]',
        daily_minutes integer NOT NULL DEFAULT 30,
        max_video_minutes integer NOT NULL DEFAULT 10,
        updated_at timestamptz NOT NULL DEFAULT now()
    )""",
    """CREATE TABLE IF NOT EXISTS app.video_queue_items (
        id uuid PRIMARY KEY,
        child_id uuid NOT NULL REFERENCES app.children(id) ON DELETE CASCADE,
        local_date date NOT NULL,
        position integer NOT NULL DEFAULT 0,
        video_id text NOT NULL,
        title text NOT NULL,
        channel_id text,
        channel_title text,
        thumbnail_url text,
        duration_seconds integer NOT NULL,
        category text,
        added_by_parent_id uuid REFERENCES app.parents(id) ON DELETE SET NULL,
        watched_seconds integer NOT NULL DEFAULT 0,
        completed_at timestamptz,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
    """CREATE INDEX IF NOT EXISTS video_queue_items_child_date_idx
        ON app.video_queue_items(child_id, local_date, position)""",
    # Email sign-up codes (email_verification.py). The account is created
    # only after the code matches; one row per address and purpose.
    """CREATE TABLE IF NOT EXISTS app.email_verifications (
        id uuid PRIMARY KEY,
        email text NOT NULL,
        purpose text NOT NULL DEFAULT 'signup',
        code_hash text NOT NULL,
        attempts integer NOT NULL DEFAULT 0,
        send_count integer NOT NULL DEFAULT 0,
        window_started_at timestamptz NOT NULL,
        last_sent_at timestamptz,
        expires_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
    """CREATE UNIQUE INDEX IF NOT EXISTS email_verifications_email_purpose_idx
        ON app.email_verifications(email, purpose)""",
    # Sign in with Apple: the encrypted refresh token that account deletion
    # revokes (apple_auth.py).
    "ALTER TABLE app.parents ADD COLUMN IF NOT EXISTS apple_refresh_token_enc text",
    # Kids' plans: events a child proposes and the parent approves or
    # declines (routers/calendar.py). Existing events are the parent's and
    # already on the calendar.
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS created_by text NOT NULL DEFAULT 'parent'",
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'approved'",
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS review_note text",
    # Never used; kids' plans live in app.events.
    "DROP TABLE IF EXISTS app.event_proposals",
    # One occurrence per task per day. Two requests in the same sync (the
    # occurrences list and the policy) both made today's occurrences, check
    # then insert, so a task could end up with two: one approved, one still
    # pending, and the phone stayed locked. Existing pairs are merged into
    # the furthest along (approved, then sent in, then sent back, then to
    # do), their photos moved onto it; then the index keeps it one.
    """UPDATE app.submissions s SET occurrence_id = r.keep_id
        FROM (SELECT id, first_value(id) OVER (
                PARTITION BY task_id, due_date
                ORDER BY CASE status WHEN 'approved' THEN 0 WHEN 'submitted' THEN 1
                                     WHEN 'rejected' THEN 2 ELSE 3 END,
                         completed_at DESC NULLS LAST, id) AS keep_id
              FROM app.occurrences) r
        WHERE s.occurrence_id = r.id AND r.id <> r.keep_id""",
    """DELETE FROM app.occurrences o
        USING (SELECT id, first_value(id) OVER (
                 PARTITION BY task_id, due_date
                 ORDER BY CASE status WHEN 'approved' THEN 0 WHEN 'submitted' THEN 1
                                      WHEN 'rejected' THEN 2 ELSE 3 END,
                          completed_at DESC NULLS LAST, id) AS keep_id
               FROM app.occurrences) r
        WHERE o.id = r.id AND r.id <> r.keep_id""",
    """CREATE UNIQUE INDEX IF NOT EXISTS occurrences_task_day_uniq
        ON app.occurrences(task_id, due_date)""",
]


def apply_migrations(engine) -> list[str]:
    """Applies each migration statement in its own transaction, so one
    failure can't roll back the others — every statement here is IF NOT
    EXISTS / IF EXISTS and safe to (re)run on its own. (A prior version ran
    them all in one transaction: one bad statement silently rolled back
    every other one too, including columns later code assumed existed —
    e.g. tasks.due_date — which then 500'd on every write.) Returns the
    statements that failed, if any.
    """
    from sqlalchemy import text
    failed = []
    for stmt in _MIGRATIONS:
        try:
            with engine.begin() as conn:
                conn.execute(text(stmt))
        except Exception as e:
            failed.append(stmt)
            print(f"Startup migration failed ({stmt.strip().splitlines()[0]}...): {e}")
    return failed


@app.on_event("startup")
def run_migrations():
    from database import engine
    apply_migrations(engine)


app.include_router(auth.router)
app.include_router(children.router)
app.include_router(tasks.router)
app.include_router(occurrences.router)
app.include_router(submissions.router)
app.include_router(rules.router)
app.include_router(calendar.router)
app.include_router(compliance.router)
app.include_router(time_grants.router)
app.include_router(chat.router)
app.include_router(app_blocks.router)
app.include_router(live.router)
app.include_router(apps.router)
app.include_router(policy.router)
app.include_router(videos.router)

@app.get("/")
def read_root():
    return {"message": "Welcome to the Evlin Backend API"}

from sqlalchemy import text

# Columns the app relies on that were added after the original schema —
# if a migration silently failed, this is how that shows up before a user
# hits a 500 on the feature that needs it.
_EXPECTED_COLUMNS = [
    ("app.parents", "name"), ("app.tasks", "due_date"),
    ("app.events", "category"), ("app.events", "note"), ("app.events", "recurrence"),
    ("app.events", "created_by"), ("app.events", "status"), ("app.events", "review_note"),
    ("app.child_rules", "daily_limit_enabled"), ("app.child_rules", "custom_rules"),
    # A model with no matching migration is a table that doesn't exist in
    # production — the failure shows up as a 500 in whatever feature needed
    # it, long after deploy. These make a silently-failed migration visible
    # from one curl instead.
    ("app.app_blocks", "block_type"), ("app.child_memory", "fact"),
    ("app.children", "timezone"), ("app.apps", "aliases"), ("app.child_apps", "app_id"),
    ("app.app_blocks", "app_id"), ("app.app_blocks", "schedule_days"),
    ("app.child_video_profiles", "allowed_categories"), ("app.video_queue_items", "local_date"),
    ("app.email_verifications", "code_hash"), ("app.parents", "apple_refresh_token_enc"),
    ("app.chat_messages", "agent"),
]


@app.get("/health")
def health_check(db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    missing = []
    for table, column in _EXPECTED_COLUMNS:
        try:
            db.execute(text(f"SELECT {column} FROM {table} LIMIT 0"))
        except Exception:
            missing.append(f"{table}.{column}")
            db.rollback()  # the failed SELECT leaves the transaction unusable otherwise
    # R2 (photo upload) creds are set separately per environment —
    # a working local .env doesn't mean the deployed service has them, and
    # that gap shows up to a kid only as a silent "failed" upload badge with
    # no indication why. Surfacing it here makes that checkable with one
    # curl instead of guessing.
    # Open /live streams on this process. Zero while apps are open means the
    # stream isn't getting through (a buffering proxy, a failed deploy) and
    # devices are only refreshing on foreground and after their own writes.
    live_connections = live_updates.broker.subscriber_count()
    if missing or not storage_configured():
        return {
            "status": "degraded", "database": "connected",
            "missing_columns": missing, "storage_configured": storage_configured(),
            "live_connections": live_connections,
        }
    return {"status": "healthy", "database": "connected", "storage_configured": True,
            "live_connections": live_connections}
