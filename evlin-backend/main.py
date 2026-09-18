from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from routers import auth, tasks, occurrences, submissions, rules, calendar, children, compliance

app = FastAPI(title="Evlin Backend API", description="API for the Evlin iOS app")

app.include_router(auth.router)
app.include_router(children.router)
app.include_router(tasks.router)
app.include_router(occurrences.router)
app.include_router(submissions.router)
app.include_router(rules.router)
app.include_router(calendar.router)
app.include_router(compliance.router)

@app.get("/")
def read_root():
    return {"message": "Welcome to the Evlin Backend API"}

@app.get("/health")
def health_check(db: Session = Depends(get_db)):
    try:
        # Check DB connection
        db.execute("SELECT 1")
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
