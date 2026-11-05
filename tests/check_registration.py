import os
from pathlib import Path
from uuid import uuid4

import psycopg
from dotenv import load_dotenv
from werkzeug.security import generate_password_hash, check_password_hash


PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env", interpolate=False)


def main():
    if os.environ["DB_USER"] != "hospital_app":
        raise RuntimeError("Run this test as hospital_app.")

    # A temporary test password, never printed or committed to the database.
    password = uuid4().hex
    password_hash = generate_password_hash(password, method="scrypt")

    assert check_password_hash(password_hash, password)
    assert not check_password_hash(password_hash, "wrong-password")
    print("PASS 1: password hashing and verification work")

    email = f"registration-{uuid4().hex}@example.test"

    with psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        application_name="Veya registration test",
    ) as connection:
        try:
            with connection.cursor() as cursor:
                cursor.execute("""
                    SELECT hospital.register_patient(%s, %s, %s, %s)
                """, (
                    email,
                    password_hash,
                    "Registration Test Patient",
                    "01000000000",
                ))

                user_id = cursor.fetchone()[0]
                assert isinstance(user_id, int) and user_id > 0
                print("PASS 2: patient registration succeeded")

                # A nested transaction creates a savepoint.
                # An expected error rolls back only this attempted operation.
                try:
                    with connection.transaction():
                        cursor.execute("""
                            SELECT hospital.register_patient(%s, %s, %s, %s)
                        """, (
                            email.upper(),
                            password_hash,
                            "Duplicate Test Patient",
                            "01000000000",
                        ))
                except psycopg.errors.UniqueViolation:
                    print("PASS 3: duplicate email rejected, ignoring case")
                else:
                    raise AssertionError("Duplicate email was accepted")

                try:
                    with connection.transaction():
                        cursor.execute("""
                            SELECT hospital.register_patient(%s, %s, %s, %s)
                        """, (
                            f"invalid-{uuid4().hex}@example.test",
                            password_hash,
                            "   ",
                            "01000000000",
                        ))
                except psycopg.errors.InvalidParameterValue:
                    print("PASS 4: blank patient name rejected")
                else:
                    raise AssertionError("Blank name was accepted")

                try:
                    with connection.transaction():
                        cursor.execute("""
                            SELECT hospital.register_patient(%s, %s, %s, %s)
                        """, (
                            f"plaintext-{uuid4().hex}@example.test",
                            "not-a-password-hash",
                            "Test Patient",
                            "01000000000",
                        ))
                except psycopg.errors.InvalidParameterValue:
                    print("PASS 5: plain-text password input rejected")
                else:
                    raise AssertionError("Plain-text password was accepted")

                try:
                    with connection.transaction():
                        cursor.execute(
                            "SELECT user_id FROM hospital.users LIMIT 0"
                        )
                except psycopg.errors.InsufficientPrivilege:
                    print("PASS 6: direct users-table access remains blocked")
                else:
                    raise AssertionError("Direct users-table access was allowed")

        finally:
            connection.rollback()
            print("ROLLBACK: test registration changes discarded")

    print("All registration checks passed.")


if __name__ == "__main__":
    main()