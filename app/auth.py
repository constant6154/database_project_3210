import os

from flask import session
from psycopg.rows import dict_row
from werkzeug.security import check_password_hash


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
                FROM hospital.patient_appointments(%s)
                ORDER BY starts_at DESC, appointment_id DESC
            """, (user_id,)).fetchall()

    except psycopg.Error as exc:
        current_app.logger.error(
            "Appointment history unavailable; SQLSTATE=%s", exc.sqlstate
        )
        return "We couldn't load your appointments. Please try again.", 503

    response = current_app.make_response(render_template(
        "my_appointments.html",
        appointments=appointments,
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