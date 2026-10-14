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
    hurt most.
    """
    import models

    sql = "\n".join(main._MIGRATIONS)
    for model in (models.AppBlock, models.App, models.ChildApp, models.ChatConversation,
                  models.ChildMemory, models.TimeGrant, models.ChildVideoProfile, models.VideoQueueItem,
                  models.EmailVerification):
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


def test_removed_features_are_dropped_not_recreated():
    """Courses, reflections and milestones were removed. Their tables must be
    dropped, in an order Postgres accepts, and nothing may create them again
    on the next boot."""
    sql = main._MIGRATIONS
    joined = "\n".join(sql)
    for table in ("courses", "course_items", "course_assignments", "course_item_progress",
                  "reflections", "reflections_legacy", "milestones"):
        assert f"DROP TABLE IF EXISTS app.{table}" in sql
        assert f"CREATE TABLE IF NOT EXISTS app.{table} " not in joined
        assert f"CREATE TABLE IF NOT EXISTS app.{table}(" not in joined

    def at(stmt):
        return sql.index(stmt)

    # Columns pointing at the tables go first; then referencing tables
    # before the tables they reference.
    for column in ("course_assignment_id", "milestone_id"):
        assert at(f"ALTER TABLE app.tasks DROP COLUMN IF EXISTS {column}") < at("DROP TABLE IF EXISTS app.course_assignments")
    for child_table in ("reflections", "milestones", "course_item_progress"):
        assert at(f"DROP TABLE IF EXISTS app.{child_table}") < at("DROP TABLE IF EXISTS app.course_assignments")
    assert at("DROP TABLE IF EXISTS app.course_assignments") < at("DROP TABLE IF EXISTS app.courses")
    assert at("DROP TABLE IF EXISTS app.course_items") < at("DROP TABLE IF EXISTS app.courses")

    # Course tasks become ordinary tasks before the constraint that no
    # longer allows 'course' is put back.
    convert = at("UPDATE app.tasks SET submission_kind = 'none' WHERE submission_kind = 'course'")
    constraint = next(i for i, s in enumerate(sql) if "tasks_submission_kind_check" in s)
    assert convert < constraint
    assert "'course'" not in sql[constraint]


def test_the_library_tables_are_dropped_and_voice_kinds_retired():
    sql = main._MIGRATIONS
    for table in ("app.lesson_slides", "app.slide_lessons", "app.comic_panels", "app.comic_guides", "content.comics"):
        assert f"DROP TABLE IF EXISTS {table}" in sql
    assert sql.index("DROP TABLE IF EXISTS app.lesson_slides") < sql.index("DROP TABLE IF EXISTS app.slide_lessons")
    assert sql.index("DROP TABLE IF EXISTS app.comic_panels") < sql.index("DROP TABLE IF EXISTS app.comic_guides")
    constraint = next(i for i, s in enumerate(sql) if "tasks_submission_kind_check" in s)
    for kind in ("either", "voice"):
        convert = next(i for i, s in enumerate(sql) if f"WHERE submission_kind = '{kind}'" in s)
        assert convert < constraint
    assert "'voice'" not in sql[constraint] and "'either'" not in sql[constraint]
    assert "ALTER TABLE app.submissions DROP COLUMN IF EXISTS duration_seconds" in sql


def test_parent_and_family_events_are_removed_and_every_event_gets_a_child():
    """Evlin keeps the children's calendars only. Parent events go, family-wide
    ones move to the only child if there is exactly one, the rest go, and
    only then can child_id become required. Nothing may add the parent
    column back."""
    sql = main._MIGRATIONS
    joined = "\n".join(sql)
    assert "ADD COLUMN IF NOT EXISTS is_parent_only" not in joined

    def at(fragment):
        return next(i for i, s in enumerate(sql) if fragment in s)

    parent_events = at("DELETE FROM app.events WHERE child_id IS NULL AND is_parent_only")
    attach = at("UPDATE app.events SET child_id = (SELECT id FROM app.children)")
    leftovers = sql.index("DELETE FROM app.events WHERE child_id IS NULL")
    drop = sql.index("ALTER TABLE app.events DROP COLUMN IF EXISTS is_parent_only")
    required = sql.index("ALTER TABLE app.events ALTER COLUMN child_id SET NOT NULL")
    assert parent_events < attach < leftovers < required
    assert parent_events < drop
