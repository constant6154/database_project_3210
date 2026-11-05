import os

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