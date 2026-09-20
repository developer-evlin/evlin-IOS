from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from routers import auth, tasks, occurrences, submissions, rules, calendar, children, compliance, content

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
    """CREATE TABLE IF NOT EXISTS app.device_pairings (
        code text PRIMARY KEY,
        secret_hash text NOT NULL,
        child_name text,
        platform text NOT NULL DEFAULT 'ios',
        child_id uuid REFERENCES app.children(id) ON DELETE CASCADE,
        expires_at timestamptz NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )""",
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
    if missing:
        return {"status": "degraded", "database": "connected", "missing_columns": missing}
    return {"status": "healthy", "database": "connected"}
