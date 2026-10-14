#!/usr/bin/env python3
"""Add or remove a test child on an Evlin parent account, straight in the
database, to see the parent app with more than one child and then put it
back.

    python scripts/test_child.py parents [--search TEXT]
    python scripts/test_child.py find EMAIL
    python scripts/test_child.py add EMAIL [--name NAME] [--yes]
    python scripts/test_child.py remove EMAIL (--child ID | --all-test) [--force] [--yes]

Run from evlin-backend/. Without --yes, add and remove only print what they
would do.

The database is the backend's own: DATABASE_URL, loaded from .env the same
way the backend loads it, unless --database-url is given. That is normally
the live database, so preview first.

A child is added by the backend's own helper
(routers.auth._create_placeholder_child), so it gets the same rules, lock
state and parent link as a real one, and removed the same way
DELETE /children/{id} removes one. The app isn't told right away: reopen it
or wait for its next sync.

Children this script adds are listed in test-children.json next to it.
remove only touches those unless --force is given, so a real child can't be
deleted by a typo.
"""
import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parent
LEDGER = HERE / "test-children.json"


def _connect(database_url):
    # Set before importing the backend: database.py reads DATABASE_URL at
    # import time, and load_dotenv never overrides a variable already set.
    if database_url:
        os.environ["DATABASE_URL"] = database_url
    sys.path.insert(0, str(BACKEND))
    os.chdir(BACKEND)  # so the backend's load_dotenv finds .env
    import database
    import models
    return database, models


def _ledger():
    try:
        return json.loads(LEDGER.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_ledger(data):
    LEDGER.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def _where(database):
    url = database.engine.url
    return f"{url.host or 'local socket'}{':' + str(url.port) if url.port else ''}/{url.database}"


def _parent(db, models, email):
    # Only id, email and name, like _children: a column a newer migration
    # adds (one the live database may not have yet) must not break this.
    parent = (db.query(models.Parent.id, models.Parent.email, models.Parent.name)
              .filter(models.Parent.email.ilike(email.strip())).first())
    if not parent:
        sys.exit(f"No parent account with the email {email}.")
    return parent


def _children(db, models, parent):
    links = db.query(models.ParentChild).filter(models.ParentChild.parent_id == parent.id).all()
    ids = [link.child_id for link in links]
    if not ids:
        return []
    # Only id and name: columns every version of the schema has, so this
    # still works on a database a newer migration hasn't reached yet.
    kids = db.query(models.Child.id, models.Child.name).filter(models.Child.id.in_(ids)).all()
    paired = {row.child_id for row in db.query(models.Device.child_id).filter(models.Device.child_id.in_(ids)).all()}
    return [(k, k.id in paired) for k in kids]


def cmd_parents(db, models, args):
    query = db.query(models.Parent.id, models.Parent.email, models.Parent.name)
    if args.search:
        like = f"%{args.search}%"
        query = query.filter(models.Parent.email.ilike(like) | models.Parent.name.ilike(like))
    rows = query.order_by(models.Parent.email).all()
    for p in rows:
        count = db.query(models.ParentChild).filter(models.ParentChild.parent_id == p.id).count()
        print(f"{p.email:40}  {p.name or '-':20}  {count} child{'ren' if count != 1 else ''}")
    print(f"{len(rows)} parent account{'s' if len(rows) != 1 else ''}")


def cmd_find(db, models, args):
    parent = _parent(db, models, args.email)
    tests = set(_ledger().get(str(parent.id), []))
    print(f"{parent.email}  ({parent.name or 'no name'})  id {parent.id}")
    kids = _children(db, models, parent)
    if not kids:
        print("  no children")
    for kid, paired in kids:
        tags = ["paired" if paired else "not paired"]
        if str(kid.id) in tests:
            tags.append("TEST, added by this script")
        print(f"  {kid.name:20}  {kid.id}  ({', '.join(tags)})")


def cmd_add(db, models, args, database):
    parent = _parent(db, models, args.email)
    name = (args.name or "Test Kid").strip()[:60]
    print(f"Database: {_where(database)}")
    print(f"Add a child named {name!r} to {parent.email}.")
    if not args.yes:
        print("Preview only. Run again with --yes to do it.")
        return
    # The same four rows routers.auth._create_placeholder_child writes, but
    # in one transaction and naming only the columns every schema version
    # has: that helper commits the child, then reloads every column, so on
    # a database a newer migration hasn't reached it would fail after the
    # child exists but before it's linked to the parent.
    import uuid
    from sqlalchemy import insert
    count = db.query(models.ParentChild).filter(models.ParentChild.parent_id == parent.id).count()
    kid_id = uuid.uuid4()
    db.execute(insert(models.Child.__table__).values(
        id=kid_id, name=name, birth_year=2015, color_index=count % 8, avatar_url=""))
    db.execute(insert(models.ParentChild.__table__).values(
        parent_id=parent.id, child_id=kid_id, role="primary"))
    db.execute(insert(models.ChildRule.__table__).values(
        child_id=kid_id, daily_limit_minutes=60, downtime_enabled=False))
    db.execute(insert(models.ChildState.__table__).values(
        child_id=kid_id, manual_lock=False, task_gate_override=False))
    db.commit()
    ledger = _ledger()
    ledger.setdefault(str(parent.id), []).append(str(kid_id))
    _save_ledger(ledger)
    print(f"Added {name} ({kid_id}). Reopen the parent app, or wait for its next sync, to see it.")


def cmd_remove(db, models, args, database):
    parent = _parent(db, models, args.email)
    ledger = _ledger()
    tests = set(ledger.get(str(parent.id), []))
    kids = {str(k.id): k for k, _ in _children(db, models, parent)}

    if args.all_test:
        targets = [cid for cid in tests if cid in kids]
    else:
        if args.child not in kids:
            sys.exit(f"{args.child} isn't one of {parent.email}'s children.")
        if args.child not in tests and not args.force:
            sys.exit(f"{kids[args.child].name} ({args.child}) wasn't added by this script, so it may be a real "
                     f"child. Pass --force to remove it anyway.")
        targets = [args.child]

    print(f"Database: {_where(database)}")
    if not targets:
        print(f"No test children to remove on {parent.email}.")
        return
    for cid in targets:
        print(f"Remove {kids[cid].name} ({cid}) from {parent.email}, with its tasks, events, rules and devices.")
    if not args.yes:
        print("Preview only. Run again with --yes to do it.")
        return
    for cid in targets:
        # Same two steps as DELETE /children/{id}; the rest cascades.
        db.query(models.ParentChild).filter(models.ParentChild.child_id == cid).delete()
        db.query(models.Child).filter(models.Child.id == cid).delete()
    db.commit()
    left = [c for c in tests if c not in targets]
    if left:
        ledger[str(parent.id)] = left
    else:
        ledger.pop(str(parent.id), None)
    _save_ledger(ledger)
    print(f"Removed {len(targets)} child{'ren' if len(targets) != 1 else ''}.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--database-url", help="Use this database instead of .env's DATABASE_URL.")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("parents", help="List parent accounts.")
    p.add_argument("--search", help="Only accounts whose email or name contains this.")

    p = sub.add_parser("find", help="Show one parent account and its children.")
    p.add_argument("email")

    p = sub.add_parser("add", help="Add a test child.")
    p.add_argument("email")
    p.add_argument("--name", help="The child's name (default: Test Kid).")
    p.add_argument("--yes", action="store_true", help="Actually write; otherwise just preview.")

    p = sub.add_parser("remove", help="Remove a test child.")
    p.add_argument("email")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--child", help="The child's id.")
    group.add_argument("--all-test", action="store_true", help="Every test child this script added to the account.")
    p.add_argument("--force", action="store_true", help="Allow removing a child this script didn't add.")
    p.add_argument("--yes", action="store_true", help="Actually write; otherwise just preview.")

    args = ap.parse_args()
    database, models = _connect(args.database_url)
    db = database.SessionLocal()
    try:
        if args.command == "parents":
            cmd_parents(db, models, args)
        elif args.command == "find":
            cmd_find(db, models, args)
        elif args.command == "add":
            cmd_add(db, models, args, database)
        else:
            cmd_remove(db, models, args, database)
    finally:
        db.close()


if __name__ == "__main__":
    main()
