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


def test_every_new_table_has_a_migration_matching_its_model():
    """A model with no migration is a table that doesn't exist in production.

    Tests build their schema from models.py directly (conftest's
    create_all), so they never touch _MIGRATIONS — which means a column
    added to a model but not to its CREATE TABLE passes the whole suite and
    then 500s on deploy. This closes that gap for the tables where it'd
    hurt most. (comic_guides/slide_lessons are deliberately excluded: they
    have models and no migrations, a pre-existing inconsistency this test
    would otherwise fail on rather than help with.)
    """
    import models

    sql = "\n".join(main._MIGRATIONS)
    for model in (models.Course, models.CourseItem, models.CourseAssignment,
                  models.CourseItemProgress, models.Reflection, models.Milestone, models.AppBlock):
        table = model.__tablename__
        assert f"app.{table}" in sql, f"{table} has a model but no migration"
        for column in model.__table__.columns:
            # Crude but effective: the CREATE TABLE text has to mention the
            # column by name somewhere.
            assert column.name in sql, f"app.{table}.{column.name} is missing from _MIGRATIONS"


def test_migrations_are_safe_to_run_twice():
    engine = _engine()
    old = main._MIGRATIONS
    main._MIGRATIONS = ["CREATE TABLE IF NOT EXISTS again (id integer)"]
    try:
        assert main.apply_migrations(engine) == []
        assert main.apply_migrations(engine) == []  # rerunning must not raise or lose the table
    finally:
        main._MIGRATIONS = old
