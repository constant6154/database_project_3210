import os
from datetime import date, datetime
from zoneinfo import ZoneInfo
from wtforms import DateField
from flask import session
from psycopg.rows import dict_row
from werkzeug.security import check_password_hash
from wtforms import SelectField
from .database import process_due_slot_offers

import psycopg
from flask import (
    Blueprint, current_app, flash,
    redirect, render_template, request, url_for,
)
from flask_wtf import FlaskForm
from werkzeug.security import generate_password_hash
from wtforms import StringField, PasswordField, SubmitField
from wtforms.validators import (
    DataRequired, Length, EqualTo, Regexp,
)


auth = Blueprint("auth", __name__)


def trim(value):
    return value.strip() if value else value


class RegistrationForm(FlaskForm):
    full_name = StringField(
        "Full name",
        filters=[trim],
        validators=[DataRequired(), Length(max=100)],
    )

    email = StringField(
        "Email address",
        filters=[trim],
        validators=[
            DataRequired(),
            Length(max=254),
            Regexp(
                r"^[^\s@]+@[^\s@]+\.[^\s@]+$",
                message="Enter a valid email address.",
            ),
        ],
    )

    phone = StringField(
        "Phone number",
        filters=[trim],
        validators=[
            DataRequired(),
            Length(min=7, max=20),
            Regexp(
                r"^\+?[0-9 ()-]+$",
                message="Enter a valid phone number.",
            ),
        ],
    )

    password = PasswordField(
        "Password",
        validators=[
            DataRequired(),
            Length(
                min=15,
                max=128,
                message="Use a password with 15 to 128 characters.",
            ),
        ],
    )

    confirm_password = PasswordField(
        "Confirm password",
        validators=[
            DataRequired(),
            EqualTo("password", message="Passwords must match."),
        ],
    )

    submit = SubmitField("Create account")


@auth.route("/register", methods=["GET", "POST"])
def register():
    form = RegistrationForm()
    page_error = None
    status = 200

    if form.validate_on_submit():
        password_hash = generate_password_hash(
            form.password.data,
            method="scrypt",
        )

        try:
            with psycopg.connect(
                host=os.environ["DB_HOST"],
                port=os.environ["DB_PORT"],
                dbname=os.environ["DB_NAME"],
                user=os.environ["DB_USER"],
                password=os.environ["DB_PASSWORD"],
                connect_timeout=5,
                application_name="Veya registration",
            ) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("""
                        SELECT hospital.register_patient(%s, %s, %s, %s)
                    """, (
                        form.email.data.lower(),
                        password_hash,
                        form.full_name.data,
                        form.phone.data,
                    ))

                    cursor.fetchone()

            # The connection block commits when it exits successfully.
            flash("Your patient account was created successfully.", "success")
            return redirect(url_for("auth.register"), code=303)

        except psycopg.errors.UniqueViolation:
            page_error = (
                "An account already uses this email address. "
                "Please use a different email."
            )
            status = 409

        except psycopg.errors.InvalidParameterValue:
            page_error = "Please check your name, email, and phone number."
            status = 400

        except psycopg.Error as exc:
            # Log the error code without logging form values or passwords.
            current_app.logger.error(
                "Registration database failure; SQLSTATE=%s",
                exc.sqlstate,
            )
            page_error = (
                "We couldn't complete registration right now. "
                "Please try again shortly."
            )
            status = 503

    elif request.method == "POST":
        status = 400

    response = current_app.make_response((
        render_template(
            "register.html",
            form=form,
            page_error=page_error,
        ),
        status,
    ))
    response.headers["Cache-Control"] = "no-store"
    return response


class LoginForm(FlaskForm):
    email = StringField(
        "Email address",
        filters=[trim],
        validators=[DataRequired(), Length(max=254)],
    )
    password = PasswordField(
        "Password",
        validators=[DataRequired(), Length(max=128)],
    )
    submit = SubmitField("Sign in")


class LogoutForm(FlaskForm):
    submit = SubmitField("Log out")


# Unknown emails still go through a password check.
DUMMY_HASH = generate_password_hash("unused-login-value", method="scrypt")


def lookup_patient(email):
    with psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        application_name="Veya patient login",
        row_factory=dict_row,
    ) as connection:
        return connection.execute(
            """
            SELECT user_id, patient_id, full_name, password_hash
            FROM hospital.lookup_patient_login(%s)
            """,
            (email,),
        ).fetchone()


@auth.route("/login", methods=["GET", "POST"])
def login():
    form = LoginForm()
    error = None
    status = 200

    if form.validate_on_submit():
        email = form.email.data.lower()
        try:
            patient = lookup_patient(email)
        except psycopg.Error:
            error = "Sign-in is temporarily unavailable. Please try again."
            status = 503
        else:
            stored_hash = patient["password_hash"] if patient else DUMMY_HASH
            password_matches = check_password_hash(
                stored_hash, form.password.data
            )

            if patient and password_matches:
                session.clear()
                session["user_id"] = patient["user_id"]
                session["email"] = email
                return redirect(url_for("auth.account"), code=303)

            error = "The email or password is incorrect."
            status = 401

    elif request.method == "POST":
        status = 400

    return render_template("login.html", form=form, error=error), status


@auth.get("/account")
def account():
    if "user_id" not in session or "email" not in session:
        return redirect(url_for("auth.login"))

    # Recheck the active account. Disabling it also closes access here.
    try:
        patient = lookup_patient(session["email"])
    except psycopg.Error:
        return "Account temporarily unavailable. Please try again.", 503

    if patient is None or patient["user_id"] != session["user_id"]:
        session.clear()
        return redirect(url_for("auth.login"))

    response = current_app.make_response(render_template(
        "account.html",
        full_name=patient["full_name"],
        logout_form=LogoutForm(),
    ))
    response.headers["Cache-Control"] = "no-store"
    return response


@auth.post("/logout")
def logout():
    form = LogoutForm()
    if not form.validate_on_submit():
        return "Please reload the account page and try again.", 400

    session.clear()
    return redirect(url_for("home"), code=303)


@auth.get("/my-appointments")
def my_appointments():
    user_id = session.get("user_id")
    email = session.get("email")

    if user_id is None or not email:
        return redirect(url_for("auth.login"))

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"))

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya appointment history",
            row_factory=dict_row,
        ) as connection:
            appointments = connection.execute("""
                SELECT
                    appointment_id,
                    doctor_name,
                    department,
                    status,
                    booked_fee,
                                        wait.request_id AS waitlist_id,
                    wait.earliest_date AS waitlist_from,
                    wait.latest_date AS waitlist_until,
                                        (status = 'Booked' AND starts_at > CURRENT_TIMESTAMP)
                        AS can_cancel,

                                            (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dhaka')::date
                        AS clinic_today,
                    (starts_at AT TIME ZONE 'Asia/Dhaka')::date - 1
                        AS last_earlier_date,
                    (status = 'Booked' AND
                        (starts_at AT TIME ZONE 'Asia/Dhaka')::date >
                        (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dhaka')::date
                    ) AS can_join_waitlist,



                    to_char(
                        starts_at AT TIME ZONE 'Asia/Dhaka',
                        'Dy, DD Mon YYYY'
                    ) AS visit_date,
                    to_char(
                        starts_at AT TIME ZONE 'Asia/Dhaka',
                        'HH12:MI AM'
                    ) AS start_time,
                    to_char(
                        ends_at AT TIME ZONE 'Asia/Dhaka',
                        'HH12:MI AM'
                    ) AS end_time
                               FROM hospital.patient_appointments(%s) AS visit
                LEFT JOIN hospital.patient_active_waitlist(%s) AS wait
                  ON wait.original_appointment_id = visit.appointment_id
                ORDER BY starts_at DESC, appointment_id DESC
            """, (user_id, user_id)).fetchall()

            offer_rows = connection.execute("""
                SELECT
                    appointment_id,
                    offer_id,
                    to_char(offered_start AT TIME ZONE 'Asia/Dhaka',
                            'Dy, DD Mon YYYY') AS visit_date,
                    to_char(offered_start AT TIME ZONE 'Asia/Dhaka',
                            'HH12:MI AM') AS start_time,
                    to_char(offered_end AT TIME ZONE 'Asia/Dhaka',
                            'HH12:MI AM') AS end_time,
                    to_char(expires_at AT TIME ZONE 'Asia/Dhaka',
                            'DD Mon YYYY, HH12:MI AM') AS deadline
                FROM hospital.patient_pending_offers(%s)
            """, (user_id,)).fetchall()

            offers_by_appointment = {
                row["appointment_id"]: row for row in offer_rows
            }



    except psycopg.Error as exc:
        current_app.logger.error(
            "Appointment history unavailable; SQLSTATE=%s", exc.sqlstate
        )
        return "We couldn't load your appointments. Please try again.", 503

    response = current_app.make_response(render_template(
        "my_appointments.html",
        appointments=appointments,
                offers_by_appointment=offers_by_appointment,

                cancel_form=CancelAppointmentForm(),
                waitlist_form=WaitlistForm(),
    ))
    response.headers["Cache-Control"] = "no-store"
    return response


class BookingForm(FlaskForm):
    submit = SubmitField("Book this slot")


@auth.app_context_processor
def booking_form_for_home():
    if request.endpoint == "home" and session.get("user_id"):
        return {"booking_form": BookingForm()}
    return {}


@auth.post("/slots/<int:slot_id>/book")
def book_slot(slot_id):
    user_id = session.get("user_id")
    email = session.get("email")

    if not user_id or not email:
        return redirect(url_for("auth.login"), code=303)

    if not BookingForm().validate_on_submit():
        return "Please reload the availability page and try again.", 400

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"), code=303)

        process_due_slot_offers()

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya booking",
        ) as connection:
            row = connection.execute(
                "SELECT hospital.book_appointment(%s, %s)",
                (patient["patient_id"], slot_id),
            ).fetchone()
            appointment_id = row[0]

        # At this point the connection has committed the booking.
        flash(f"Appointment #{appointment_id} is booked.", "success")

    except psycopg.errors.RaiseException as exc:
        message = exc.diag.message_primary
        if message == "Patient already has an overlapping appointment":
            feedback = "You already have an appointment at that time."
        elif message in {
            "Slot does not exist",
            "Slot is blocked",
            "Slot is already booked",
            "Doctor account is inactive",
            "Cannot book a slot that has already started",
        }:
            feedback = "This slot is no longer available. Please choose another."
        else:
            current_app.logger.error("Booking rejected; SQLSTATE=%s", exc.sqlstate)
            feedback = "The booking could not be completed."
        flash(feedback, "error")

    except psycopg.Error as exc:
        current_app.logger.error("Booking failed; SQLSTATE=%s", exc.sqlstate)
        return "Booking is temporarily unavailable. Check My appointments before retrying.", 503

    return redirect(url_for("auth.my_appointments"), code=303)

class CancelAppointmentForm(FlaskForm):
    submit = SubmitField("Confirm cancellation")


@auth.post("/appointments/<int:appointment_id>/cancel")
def cancel_visit(appointment_id):
    user_id = session.get("user_id")
    email = session.get("email")

    if user_id is None or not email:
        return redirect(url_for("auth.login"), code=303)

    if not CancelAppointmentForm().validate_on_submit():
        return "Please reload My appointments and try again.", 400

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"), code=303)

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya cancellation",
        ) as connection:
            row = connection.execute(
                "SELECT hospital.cancel_appointment(%s, %s)",
                (patient["patient_id"], appointment_id),
            ).fetchone()
            changed = row[0]

        if changed:
            flash(f"Appointment #{appointment_id} was cancelled.", "success")
        else:
            flash("This appointment was already cancelled.", "success")

    except psycopg.errors.RaiseException as exc:
        reasons = {
            "Cannot cancel an appointment that has started":
                "This visit has already started.",
            "Only booked appointments can be cancelled":
                "Only a booked visit can be cancelled.",
            "Appointment changed; retry cancellation":
                "This visit changed. Check its current status and try again.",
        }
        flash(
            reasons.get(exc.diag.message_primary,
                        "This appointment cannot be cancelled from your account."),
            "error",
        )

    except psycopg.Error as exc:
        current_app.logger.error("Cancellation failed; SQLSTATE=%s", exc.sqlstate)
        return "Please check My appointments before retrying cancellation.", 503

    return redirect(url_for("auth.my_appointments"), code=303)

class RescheduleForm(FlaskForm):
    slot_id = SelectField(
        "New appointment time",
        coerce=int,
        validators=[DataRequired(message="Choose an available time.")],
    )
    submit = SubmitField("Confirm new time")


@auth.route("/appointments/<int:appointment_id>/reschedule",
            methods=["GET", "POST"])
def reschedule_visit(appointment_id):
    user_id = session.get("user_id")
    email = session.get("email")

    if user_id is None or not email:
        return redirect(url_for("auth.login"), code=303)

    form = RescheduleForm()
    status_code = 200

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"), code=303)

        process_due_slot_offers()

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya rescheduling",
            row_factory=dict_row,
        ) as connection:
            # Find this appointment among the signed-in patient's visits.
            visit = connection.execute("""
                SELECT doctor_name, department,
                       to_char(starts_at AT TIME ZONE 'Asia/Dhaka',
                               'Dy, DD Mon YYYY · HH12:MI AM') AS current_time
                FROM hospital.patient_appointments(%s)
                WHERE appointment_id = %s
                  AND status = 'Booked'
                  AND starts_at > CURRENT_TIMESTAMP
            """, (user_id, appointment_id)).fetchone()

            if visit is None:
                flash("This appointment is unavailable for rescheduling.", "error")
                return redirect(url_for("auth.my_appointments"), code=303)

            slots = connection.execute("""
                SELECT slot_id, doctor_name, consultation_fee,
                       to_char(starts_at AT TIME ZONE 'Asia/Dhaka',
                               'Dy, DD Mon YYYY · HH12:MI AM') AS new_time
                FROM hospital.available_slots
                WHERE department = %s
                ORDER BY starts_at, doctor_id, slot_id
            """, (visit["department"],)).fetchall()

            form.slot_id.choices = [
                (slot["slot_id"],
                 f"{slot['new_time']} · {slot['doctor_name']} · "
                 f"Tk {slot['consultation_fee']:.2f}")
                for slot in slots
            ]

            if form.validate_on_submit():
                result = connection.execute("""
                    SELECT hospital.reschedule_appointment(%s, %s, %s)
                           AS new_id
                """, (
                    patient["patient_id"],
                    appointment_id,
                    form.slot_id.data,
                )).fetchone()
            elif request.method == "POST":
                status_code = 400

        # The database transaction has committed before success is shown.
        if request.method == "POST" and status_code == 200:
            flash(f"Visit moved. Your new appointment is #{result['new_id']}.",
                  "success")
            return redirect(url_for("auth.my_appointments"), code=303)

    except psycopg.errors.RaiseException as exc:
        if exc.diag.message_primary == "Patient already has an overlapping appointment":
            message = "You already have a visit at that time. Choose another slot."
        else:
            message = "The visit could not be moved. Check its status and choose an available time."
        flash(message, "error")
        return redirect(url_for("auth.my_appointments"), code=303)

    except psycopg.Error as exc:
        current_app.logger.error("Rescheduling failed; SQLSTATE=%s", exc.sqlstate)
        return "Please check My appointments before retrying.", 503

    response = current_app.make_response((
        render_template("reschedule.html", visit=visit, form=form),
        status_code,
    ))
    response.headers["Cache-Control"] = "no-store"
    return response

class WaitlistForm(FlaskForm):
    earliest_date = DateField("Earliest date", validators=[DataRequired()])
    latest_date = DateField("Latest date", validators=[DataRequired()])


@auth.post("/appointments/<int:appointment_id>/waitlist")
def join_waitlist(appointment_id):
    user_id = session.get("user_id")
    email = session.get("email")

    if user_id is None or not email:
        return redirect(url_for("auth.login"), code=303)

    form = WaitlistForm()

    if not form.validate_on_submit():
        if form.csrf_token.errors:
            message = "Please reload My appointments and submit the request again."
        else:
            message = "Please enter both dates."
        flash(message, "error")
        return redirect(url_for("auth.my_appointments"), code=303)

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"), code=303)

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya waitlist",
        ) as connection:
            request_id = connection.execute(
                "SELECT hospital.join_waitlist(%s, %s, %s, %s)",
                (
                    patient["patient_id"],
                    appointment_id,
                    form.earliest_date.data,
                    form.latest_date.data,
                ),
            ).fetchone()[0]

        flash(
            f"Waitlist request #{request_id} was saved. "
            "Your original appointment is still booked.",
            "success",
        )

    except psycopg.errors.RaiseException as exc:
        reasons = {
            "This appointment already has an active waitlist request":
                "You already have an active request for this visit.",
            "Choose dates from today through the day before your booked visit":
                "Choose a range from today through the day before your visit.",
            "Only a future booked appointment can join the waitlist":
                "Only an upcoming booked visit can join the waitlist.",
        }
        flash(
            reasons.get(exc.diag.message_primary,
                        "This visit is unavailable for a waitlist request."),
            "error",
        )

    except psycopg.Error as exc:
        current_app.logger.error("Waitlist request failed; SQLSTATE=%s", exc.sqlstate)
        return "Waitlist temporarily unavailable. Please try again shortly.", 503

    return redirect(url_for("auth.my_appointments"), code=303)


@auth.post("/offers/<int:offer_id>/accept")
def accept_offer(offer_id):
    user_id = session.get("user_id")
    email = session.get("email")

    if user_id is None or not email:
        return redirect(url_for("auth.login"), code=303)

    if not FlaskForm().validate_on_submit():
        return "Please reload My appointments and try again.", 400

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"), code=303)

        process_due_slot_offers()

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya offer acceptance",
        ) as connection:
            row = connection.execute(
                "SELECT hospital.accept_slot_offer(%s, %s)",
                (user_id, offer_id),
            ).fetchone()
            appointment_id = row[0]

    except psycopg.errors.RaiseException as exc:
        message = exc.diag.message_primary
        if message in {
            "Offer unavailable for this account",
            "Earlier-visit offer is no longer available",
            "Original appointment is no longer eligible",
        }:
            flash("This offer is no longer available to accept.", "error")
        elif message == "Patient already has an overlapping appointment":
            flash("You already have an appointment at that time.", "error")
        else:
            current_app.logger.exception("Earlier-visit acceptance failed")
            flash("We couldn't move your appointment. Please check your visits.", "error")

    except psycopg.Error:
        current_app.logger.exception("Database error during offer acceptance")
        flash("Please refresh My appointments to check your booking.", "error")

    else:
        flash(f"Earlier visit confirmed. Appointment #{appointment_id} is booked.", "success")

    return redirect(url_for("auth.my_appointments"), code=303)



@auth.post("/offers/<int:offer_id>/decline")
def decline_offer(offer_id):
    user_id = session.get("user_id")
    email = session.get("email")

    if user_id is None or not email:
        return redirect(url_for("auth.login"), code=303)

    if not FlaskForm().validate_on_submit():
        return "Please reload My appointments and try again.", 400

    try:
        patient = lookup_patient(email)
        if patient is None or patient["user_id"] != user_id:
            session.clear()
            return redirect(url_for("auth.login"), code=303)

        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya offer decline",
        ) as connection:
            row = connection.execute(
                "SELECT hospital.decline_slot_offer(%s, %s)",
                (user_id, offer_id),
            ).fetchone()
            outcome = row[0]

    except psycopg.errors.RaiseException as exc:
        if exc.diag.message_primary in {
            "Offer unavailable for this account",
            "This offer is already closed",
        }:
            flash("This offer is no longer available to decline.", "error")
        else:
            current_app.logger.exception("Earlier-visit decline failed")
            flash("We couldn't confirm the decline. Please check your visits.", "error")

    except psycopg.Error:
        current_app.logger.exception("Database error while declining an offer")
        flash("We couldn't confirm the decline. Please check your visits.", "error")

    else:
        if outcome == "Declined":
            flash(
                "Earlier visit declined. Your original appointment is still booked "
                "and you’re still on the waitlist.",
                "success",
            )
        elif outcome == "Expired":
            flash("The response deadline for this offer has passed.", "error")

    return redirect(url_for("auth.my_appointments"), code=303)



@auth.before_app_request
def process_due_offers_before_visit():
    endpoint = request.endpoint

    if endpoint != "home" and request.blueprint != auth.name:
        return None

    if endpoint in {
        "auth.login", "auth.logout", "auth.register", "auth.account",
        "auth.staff_login", "auth.staff_account",
    }:
        return None

    try:
        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=os.environ["DB_PORT"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=5,
            application_name="Veya offer expiry",
            autocommit=True,
        ) as connection:
            processed = connection.execute(
                "SELECT hospital.process_due_slot_offers()"
            ).fetchone()[0]

    except psycopg.Error:
        current_app.logger.exception("Could not process overdue visit offers")
        return "Appointment availability is temporarily unavailable. Please retry.", 503

    if processed:
        current_app.logger.info("Processed %d overdue visit offer(s)", processed)

    return None


def staff_connection():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        application_name="Veya staff",
        row_factory=dict_row,
    )


def lookup_staff(email):
    with staff_connection() as connection:
        return connection.execute(
            """
            SELECT user_id, email, password_hash
            FROM hospital.lookup_staff_login(%s)
            """,
            (email,),
        ).fetchone()


@auth.route("/staff/login", methods=["GET", "POST"])
def staff_login():
    form = LoginForm()
    error = None
    status = 200
    if form.validate_on_submit():
        try:
            staff = lookup_staff(form.email.data)
        except psycopg.Error:
            current_app.logger.exception("Staff sign-in lookup failed")
            error = "Staff sign-in is temporarily unavailable."
            status = 503
        else:
            stored_hash = staff["password_hash"] if staff else DUMMY_HASH
            matches = check_password_hash(stored_hash or DUMMY_HASH, form.password.data)
            if staff and matches:
                session.clear()
                session["staff_user_id"] = staff["user_id"]
                session["staff_email"] = staff["email"]
                return redirect(url_for("auth.staff_account"), code=303)
            error = "Incorrect staff email or password."
            status = 401
    elif request.method == "POST":
        status = 400
    return render_template("staff_login.html", form=form, error=error), status


@auth.route("/staff", methods=["GET", "POST"])
def staff_account():
    email = session.get("staff_email")
    user_id = session.get("staff_user_id")
    if not email or user_id is None:
        return redirect(url_for("auth.staff_login"))
    try:
        staff = lookup_staff(email)
    except psycopg.Error:
        current_app.logger.exception("Staff account lookup failed")
        return "Staff account temporarily unavailable.", 503
    if staff is None or staff["user_id"] != user_id:
        session.clear()
        return redirect(url_for("auth.staff_login"))
    form = LogoutForm()
    today = datetime.now(ZoneInfo("Asia/Dhaka")).date()
    try:
        day = date.fromisoformat(request.args.get("day", today.isoformat()))
    except ValueError:
        return "Choose a valid clinic date.", 400
    try:
        with staff_connection() as connection:
            if request.method == "POST":
                if not form.validate_on_submit():
                    return "Reload the staff page before submitting.", 400
                created = connection.execute(
                    "SELECT hospital.refresh_clinic_slots() AS count"
                ).fetchone()["count"]
            else:
                visits = connection.execute(
                    "SELECT * FROM hospital.staff_day(%s)", (day,)
                ).fetchall()
    except psycopg.Error:
        current_app.logger.exception("Staff dashboard query failed")
        return "Staff schedule unavailable. Check that migration 36 was applied.", 503
    if request.method == "POST":
        flash(f"{created} new appointment slots generated.")
        return redirect(url_for("auth.staff_account", day=day), code=303)
    return render_template(
        "staff_account.html", email=email, form=form, day=day, visits=visits
    ), 200, {"Cache-Control": "no-store"}
