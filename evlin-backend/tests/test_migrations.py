"""Regression test for the startup-migration bug: one bad statement used to
roll back every other statement in the same batch (they all shared one
transaction), silently leaving columns like tasks.due_date missing and
turning task creation into a 500. main.apply_migrations() now isolates each
statement in its own transaction; this proves that isolation holds, using
generic SQL (SQLite, not Postgres) so it exercises the mechanism, not the
specific ALTER TABLE syntax.
"""
from sqlalchemy import create_engine, text
from sqlalchemy.pool import StaticPool

import main


def _engine():
    return create_engine("sqlite://", poolclass=StaticPool, connect_args={"check_same_thread": False})


def test_a_failing_statement_does_not_block_the_ones_after_it():
    engine = _engine()
    statements = [
        "CREATE TABLE ok_before (id integer)",
        "this is not valid sql",
        "CREATE TABLE ok_after (id integer)",
    ]
    old = main._MIGRATIONS
    main._MIGRATIONS = statements
    try:
        failed = main.apply_migrations(engine)
    finally:
        main._MIGRATIONS = old

    assert failed == ["this is not valid sql"]
    with engine.connect() as conn:
        tables = {r[0] for r in conn.execute(text("SELECT name FROM sqlite_master WHERE type='table'"))}
    assert {"ok_before", "ok_after"} <= tables


def test_migrations_are_safe_to_run_twice():
    engine = _engine()
    old = main._MIGRATIONS
    main._MIGRATIONS = ["CREATE TABLE IF NOT EXISTS again (id integer)"]
    try:
        assert main.apply_migrations(engine) == []
        assert main.apply_migrations(engine) == []  # rerunning must not raise or lose the table
    finally:
        main._MIGRATIONS = old
