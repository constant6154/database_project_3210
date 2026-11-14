import os

import psycopg


def process_due_slot_offers():
    with psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        application_name="Veya offer expiry",
    ) as connection:
        row = connection.execute(
            "SELECT hospital.process_due_slot_offers()"
        ).fetchone()

    return row[0]
