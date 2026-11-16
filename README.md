# Veya · Hospital appointment scheduling

Veya helps patients find a doctor, book a visit and request an earlier appointment. When a cancellation frees a suitable slot, the clinic can offer it to a waiting patient and measure how often those visits are recovered.

**Python 3.13 · Flask · Jinja · Psycopg · PostgreSQL**

## How the clinic works

| Workflow | Database implementation |
| --- | --- |
| Generate dated slots from active doctors’ weekly schedules. An immediate repeat refresh skips existing intervals. | [Slot generation](database/10_generate_slots.sql) |
| Move a visit in one transaction so a failed replacement preserves the original appointment. | [Rescheduling](database/06_reschedule_appointment.sql) |
| Offer cancelled slots to eligible waiting patients and hold them out of public availability. | [Cancellation trigger](database/27_cancellation_offers.sql) · [Offer acceptance](database/29_accept_slot_offer.sql) · [Slot holds](database/33_hold_pending_slots.sql) |
| Count distinct cancellations recovered and the outcomes of individual offers. | [Recovery report](database/34_clinic_recovery_report.sql) |
| Sign in as staff, refresh 28 days of slots and inspect appointments for one Dhaka calendar date. | [Staff lookup](database/35_staff_login_lookup.sql) · [Staff dashboard](database/36_staff_dashboard.sql) |

## Try it in two browser sessions

1. Open `/staff/login` and refresh the clinic slots. Repeat the refresh and compare the inserted count.
2. In a separate patient session, filter availability by department and date on `/`, book a slot and find that visit on the staff roster.
3. With two test patients, place the later visit on the waitlist. Cancel the earlier visit with the same doctor inside the requested dates. Accept the resulting offer from the waiting patient's account.
4. Run `SELECT * FROM hospital.clinic_recovery_report;` in pgAdmin to compare cancellations, offers and recovered visits.

## Update the existing PC database

Open hospital_db as postgres. Apply database/35_staff_login_lookup.sql and database/36_staff_dashboard.sql. Both can be run again. Start run.py using the project virtual environment. Sign in as staff, refresh the slots twice and check that the second refresh adds zero. Book a slot from a separate patient browser session and look up that date on the staff page.

## Move the working project to a laptop

1. Back up hospital_db on the PC using pgAdmin Backup in Custom format. Transfer the backup privately. The recovery report is included in this repository.
2. Install the same PostgreSQL major version on the laptop with btree_gist available. In a fresh cluster create roles hospital_app (LOGIN) and hospital_routine_owner (NOLOGIN), both without superuser privileges. Set a private password for hospital_app. Create an empty hospital_db. Restore the backup as postgres preserving ownership and privileges. Check the restore log for errors.
3. As postgres run ALTER ROLE hospital_app IN DATABASE hospital_db SET timezone = 'Asia/Dhaka'; and ALTER ROLE hospital_app IN DATABASE hospital_db SET default_transaction_isolation = 'read committed';
4. Clone main from this repository. Create a fresh virtual environment with Python 3.13 and install requirements.txt. Copy the private .env separately and adjust DB_HOST, DB_PORT and DB_PASSWORD for the laptop. Keep DB_NAME=hospital_db and DB_USER=hospital_app.
5. Run python run.py from the activated environment. Verify staff sign-in, a known patient's bookings and public availability. Keep the original database until these checks pass.

### Launch on Windows

From the cloned folder containing `run.py`, after restoring the database and configuring the root `.env` with its database settings and a strong `SECRET_KEY` of at least 32 characters:

```powershell
py -3.13 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe run.py
```

Open http://127.0.0.1:5000 in a browser.
