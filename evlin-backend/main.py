from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from routers import auth, tasks, occurrences, submissions, rules, calendar, children, compliance, content, time_grants
from storage import storage_configured

app = FastAPI(title="Evlin Backend API", description="API for the Evlin iOS app")


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
    "ALTER TABLE app.events ADD COLUMN IF NOT EXISTS is_parent_only boolean NOT NULL DEFAULT false",
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
    # is what a "special task" grants once its occurrence is approved.
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
app.include_router(content.router)
app.include_router(time_grants.router)

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
    ("app.child_rules", "daily_limit_enabled"), ("app.child_rules", "custom_rules"),
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
    # R2 (photo/voice upload) creds are set separately per environment —
    # a working local .env doesn't mean the deployed service has them, and
    # that gap shows up to a kid only as a silent "failed" upload badge with
    # no indication why. Surfacing it here makes that checkable with one
    # curl instead of guessing.
    if missing or not storage_configured():
        return {
            "status": "degraded", "database": "connected",
            "missing_columns": missing, "storage_configured": storage_configured(),
        }
    return {"status": "healthy", "database": "connected", "storage_configured": True}
