import os
from datetime import date
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
from dotenv import load_dotenv
from flask import Flask, render_template, request


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
        department = request.args.get("department", "").strip()
        selected_date = request.args.get("date", "").strip()

        appointment_day = None
        filter_error = None
        departments = []
        slots = []

        if selected_date:
            try:
                appointment_day = date.fromisoformat(selected_date)
                selected_date = appointment_day.isoformat()
            except ValueError:
                filter_error = "Please choose a valid appointment date."
                selected_date = ""

        context = {
            "selected_department": department,
            "selected_date": selected_date,
            "filter_error": filter_error,
            "departments": departments,
            "slots": slots,
            "doctor_count": 0,
            "department_count": 0,
            "error": False,
        }

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
                    # Keep all available departments in the dropdown,
                    # even when a filter is applied.
                    cursor.execute("""
                        SELECT DISTINCT department
                        FROM hospital.available_slots
                        ORDER BY department
                    """)
                    departments = [
                        row["department"] for row in cursor.fetchall()
                    ]
                    context["departments"] = departments

                    if department and department not in departments:
                        filter_error = (
                            "That department currently has no available slots. "
                            "Please choose another department."
                        )

                    context["filter_error"] = filter_error

                    if not filter_error:
                        conditions = []
                        parameters = []

                        if department:
                            conditions.append("department = %s")
                            parameters.append(department)

                        if appointment_day is not None:
                            conditions.append("""
                                (starts_at AT TIME ZONE 'Asia/Dhaka')::date
                                = %s
                            """)
                            parameters.append(appointment_day)

                        query = """
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
                        """

                        if conditions:
                            query += " WHERE " + " AND ".join(conditions)

                        query += """
                            ORDER BY starts_at, doctor_id, slot_id
                            LIMIT 100
                        """

                        # Values are passed separately from SQL.
                        cursor.execute(query, parameters)
                        slots = cursor.fetchall()

        except psycopg.Error:
            app.logger.exception("Could not load available slots")
            context["error"] = True
            return render_template("home.html", **context), 503

        context.update(
            slots=slots,
            doctor_count=len({slot["doctor_id"] for slot in slots}),
            department_count=len({
                slot["department"] for slot in slots
            }),
        )

        return render_template(
            "home.html", **context
        ), 400 if filter_error else 200

    return app