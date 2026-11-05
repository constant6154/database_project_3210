BEGIN;

CREATE ROLE hospital_app
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;

GRANT CONNECT ON DATABASE hospital_db TO hospital_app;

-- Remove access inherited through PUBLIC in our project schema.
REVOKE ALL ON SCHEMA hospital FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA hospital FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA hospital FROM PUBLIC;
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA hospital FROM PUBLIC;

-- Allow access to the schema and the availability view only.
GRANT USAGE ON SCHEMA hospital TO hospital_app;
GRANT SELECT ON hospital.available_slots TO hospital_app;

ALTER ROLE hospital_app IN DATABASE hospital_db
    SET timezone = 'Asia/Dhaka';

ALTER ROLE hospital_app IN DATABASE hospital_db
    SET default_transaction_isolation = 'read committed';

COMMIT;