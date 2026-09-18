import os
from datetime import datetime, timezone
from sqlalchemy.orm import Session
from database import SessionLocal
import models

def generate_daily_occurrences():
    db: Session = SessionLocal()
    try:
        today = datetime.now(timezone.utc).date()
        print(f"Running nightly cron job for {today}...")
        
        # Get all active tasks
        tasks = db.query(models.Task).filter(models.Task.active == True).all()
        created_count = 0
        
        for task in tasks:
            # MVP: Assuming daily tasks. Can be expanded for 'weekly' checking weekdays.
            if task.recurrence in ['daily', 'none']:
                # Check if it already exists to prevent duplicates
                existing = db.query(models.Occurrence).filter(
                    models.Occurrence.task_id == task.id,
                    models.Occurrence.due_date == today
                ).first()
                
                if not existing:
                    new_occurrence = models.Occurrence(
                        task_id=task.id,
                        child_id=task.child_id,
                        due_date=today,
                        due_time=task.due_time,
                        status="pending",
                        gates_apps=task.gates_apps,
                        points=task.points
                    )
                    db.add(new_occurrence)
                    created_count += 1
                    
        db.commit()
        print(f"Successfully generated {created_count} new occurrences for {today}.")
    except Exception as e:
        print(f"Error generating occurrences: {e}")
        db.rollback()
    finally:
        db.close()

if __name__ == "__main__":
    generate_daily_occurrences()
