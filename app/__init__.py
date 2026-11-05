import os
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
from dotenv import load_dotenv
from flask import Flask, render_template


PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env", interpolate=False)


def create_app():
    app = Flask(__name__)

    required = [
        "DB_HOST", "DB_PORT", "DB_NAME",
        "DB_USER", "DB_PASSWORD",
    ]

    missing = [name for name in required if not os.getenv(name)]

    if missing:
        raise RuntimeError(
            "Missing configuration: " + ", ".join(missing)
        )

    if os.environ["DB_USER"] != "hospital_app":
        raise RuntimeError("Veya must connect as hospital_app.")

    @app.get("/")
    def home():
        try:
            with psycopg.connect(
                host=os.environ["DB_HOST"],
                port=os.environ["DB_PORT"],
                dbname=os.environ["DB_NAME"],
                user=os.environ["DB_USER"],
                password=os.environ["DB_PASSWORD"],
                connect_timeout=5,
                application_name="Veya",
                row_factory=dict_row,
            ) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("""
                        SELECT
                            slot_id,
                            doctor_id,
                            doctor_name,
                            department,
                            consultation_fee,
                            to_char(
                                starts_at AT TIME ZONE 'Asia/Dhaka',
                                'Dy, DD Mon YYYY'
                            ) AS appointment_date,
                            to_char(
                                starts_at AT TIME ZONE 'Asia/Dhaka',
                                'HH12:MI AM'
                            ) AS start_time,
                            to_char(
                                ends_at AT TIME ZONE 'Asia/Dhaka',
                                'HH12:MI AM'
                            ) AS end_time
                        FROM hospital.available_slots
                        ORDER BY starts_at, doctor_id, slot_id
                        LIMIT 100
                    """)

                    slots = cursor.fetchall()

        except psycopg.Error:
            app.logger.exception("Could not load available slots")

            return render_template(
                "home.html",
                slots=[],
                doctor_count=0,
                department_count=0,
                error=True,
            ), 503

        return render_template(
            "home.html",
            slots=slots,
            doctor_count=len({slot["doctor_id"] for slot in slots}),
            department_count=len({
                slot["department"] for slot in slots
            }),
            error=False,
        )

    return app