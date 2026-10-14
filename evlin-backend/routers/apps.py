"""The app catalog and each child's lockable list. See app_catalog.py."""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

import models
import schemas
from access import assert_child_access, assert_parent_owns_child
from database import get_db
from routers.auth import get_current_parent

router = APIRouter(tags=["apps"])


def child_apps(db: Session, child_id: UUID) -> list[models.App]:
    """This child's lockable apps, by name."""
    return db.query(models.App).join(
        models.ChildApp, models.ChildApp.app_id == models.App.id
    ).filter(models.ChildApp.child_id == child_id).order_by(models.App.name).all()


@router.get("/apps", response_model=list[schemas.AppResponse])
def list_catalog(_parent: models.Parent = Depends(get_current_parent), db: Session = Depends(get_db)):
    """Everything a parent can put on a child's list."""
    return db.query(models.App).order_by(models.App.name).all()


@router.get("/children/{child_id}/apps", response_model=list[schemas.AppResponse])
def get_child_apps(child_id: UUID, db: Session = Depends(get_db),
                   _access: None = Depends(assert_child_access)):
    """Both sides: the parent editing it, and the child's device, which has
    to know what a lock covers."""
    return child_apps(db, child_id)


@router.put("/children/{child_id}/apps", response_model=list[schemas.AppResponse])
def set_child_apps(child_id: UUID, body: schemas.ChildAppsUpdate,
                   current_parent: models.Parent = Depends(get_current_parent),
                   db: Session = Depends(get_db)):
    """Replace the list. Apps already on it keep their row (and who added
    them); only real additions and removals are written, so saving an
    unchanged list announces nothing."""
    assert_parent_owns_child(db, current_parent, child_id)
    wanted = set(body.app_ids)
    known = {a for (a,) in db.query(models.App.id).filter(models.App.id.in_(wanted)).all()} if wanted else set()
    if unknown := wanted - known:
        raise HTTPException(status_code=400, detail=f"Unknown app ids: {sorted(str(u) for u in unknown)}")

    current = {row.app_id: row for row in db.query(models.ChildApp).filter(models.ChildApp.child_id == child_id).all()}
    for app_id, row in current.items():
        if app_id not in wanted:
            db.delete(row)
    for app_id in wanted - current.keys():
        db.add(models.ChildApp(child_id=child_id, app_id=app_id, added_by="parent"))
    db.commit()
    return child_apps(db, child_id)
