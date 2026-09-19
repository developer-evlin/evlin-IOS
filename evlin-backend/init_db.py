import os
import sqlalchemy
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise ValueError("DATABASE_URL is not set.")

engine = sqlalchemy.create_engine(DATABASE_URL)

sql_file_path = "../evlin-tables.sql"

with open(sql_file_path, "r") as file:
    sql_script = file.read()

# Execute the SQL script
with engine.connect() as conn:
    # Need to run it as text
    for statement in sql_script.split(';'):
        if statement.strip():
            try:
                conn.execute(sqlalchemy.text(statement))
            except Exception as e:
                print(f"Error executing statement: {statement}")
                print(e)
    conn.commit()

print("Database initialized successfully.")
