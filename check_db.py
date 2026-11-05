import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv


PROJECT_ROOT = Path(__file__).resolve().parent
load_dotenv(PROJECT_ROOT / ".env", interpolate=False)


def main():
    required = [
        "DB_HOST",
        "DB_PORT",
        "DB_NAME",
        "DB_USER",
        "DB_PASSWORD",
    ]

    missing = [name for name in required if not os.getenv(name)]

    if missing:
        raise SystemExit(
            "Missing configuration: " + ", ".join(missing)
        )

    with psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        application_name="Veya connection check",
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT current_user, current_database()"
            )
            username, database = cursor.fetchone()

            if username != "hospital_app":
                raise SystemExit(
                    "Use hospital_app for this connection check."
                )

            cursor.execute(
                "SELECT count(*) FROM hospital.available_slots"
            )
            available_slots = cursor.fetchone()[0]

            cursor.execute("SHOW timezone")
            timezone = cursor.fetchone()[0]

            print("Veya database connection successful!")
            print(f"Database: {database}")
            print(f"Connected as: {username}")
            print(f"Timezone: {timezone}")
            print(f"Available slots: {available_slots}")


if __name__ == "__main__":
    main()