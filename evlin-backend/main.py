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


@app.on_event("startup")
def run_migrations():
    from sqlalchemy import text
    from database import engine
    try:
        with engine.begin() as conn:
            for stmt in _MIGRATIONS:
                conn.execute(text(stmt))
    except Exception as e:  # never keep the API from booting over this
        print(f"Startup migration failed: {e}")


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

@app.get("/health")
def health_check(db: Session = Depends(get_db)):
    try:
        # Check DB connection
        db.execute(text("SELECT 1"))
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
