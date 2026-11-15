# Veya hospital appointments

Patients can register, book, reschedule, cancel and respond to earlier-visit offers. Active administrators use /staff/login to review a day's appointments and generate upcoming slots from the doctors' schedules.

## Update the existing PC database

Open hospital_db as postgres. Apply database/35_staff_login_lookup.sql and database/36_staff_dashboard.sql. Both can be run again. Start run.py using the project virtual environment. Sign in as staff, refresh the slots twice and check that the second refresh adds zero. Book a slot from a separate patient browser session and look up that date on the staff page.

## Move the working project to a laptop

1. Back up hospital_db on the PC using pgAdmin Backup in Custom format. Copy the backup privately alongside any untracked project SQL, including the local recovery report.
2. Install the same PostgreSQL major version on the laptop with btree_gist available. In a fresh cluster create roles hospital_app (LOGIN) and hospital_routine_owner (NOLOGIN), both without superuser privileges. Set a private password for hospital_app. Create an empty hospital_db. Restore the backup as postgres preserving ownership and privileges. Check the restore log for errors.
3. As postgres run ALTER ROLE hospital_app IN DATABASE hospital_db SET timezone = 'Asia/Dhaka'; and ALTER ROLE hospital_app IN DATABASE hospital_db SET default_transaction_isolation = 'read committed';
4. Clone the branch containing the dashboard. Create a fresh virtual environment with Python 3.13 and install requirements.txt. Copy the private .env separately and adjust DB_HOST, DB_PORT and DB_PASSWORD for the laptop. Keep DB_NAME=hospital_db and DB_USER=hospital_app.
5. Run python run.py from the activated environment. Verify staff sign-in, a known patient's bookings and public availability. Keep the original database until these checks pass.
