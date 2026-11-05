BEGIN;

CREATE ROLE hospital_routine_owner
    NOLOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;

GRANT USAGE ON SCHEMA hospital TO hospital_routine_owner;

-- Data needed by the booking routines.
GRANT SELECT ON
    hospital.patients,
    hospital.doctors,
    hospital.appointment_slots,
    hospital.appointments
TO hospital_routine_owner;

GRANT SELECT (user_id, is_active)
ON hospital.users TO hospital_routine_owner;

-- Row-locking statements require UPDATE permission on
-- at least one column of each locked table.
GRANT UPDATE (patient_id)
ON hospital.patients TO hospital_routine_owner;

GRANT UPDATE (doctor_id)
ON hospital.doctors TO hospital_routine_owner;

GRANT UPDATE (slot_id)
ON hospital.appointment_slots TO hospital_routine_owner;

GRANT UPDATE (is_active)
ON hospital.users TO hospital_routine_owner;

-- Actual writes performed by booking and cancellation.
GRANT INSERT ON hospital.appointments
TO hospital_routine_owner;

GRANT UPDATE (status, updated_at)
ON hospital.appointments TO hospital_routine_owner;

-- The existing audit trigger runs during these operations.
GRANT INSERT ON hospital.appointment_audit
TO hospital_routine_owner;

-- Grant access to the two identity sequences by looking
-- up their actual names.
DO $$
DECLARE
    v_sequence text;
BEGIN
    v_sequence := pg_get_serial_sequence(
        'hospital.appointments', 'appointment_id'
    );

    EXECUTE format(
        'GRANT USAGE ON SEQUENCE %s TO hospital_routine_owner',
        v_sequence
    );

    v_sequence := pg_get_serial_sequence(
        'hospital.appointment_audit', 'audit_id'
    );

    EXECUTE format(
        'GRANT USAGE ON SEQUENCE %s TO hospital_routine_owner',
        v_sequence
    );
END;
$$;

-- Temporarily allow function ownership transfer.
GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER FUNCTION hospital.book_appointment(bigint, bigint, text)
    OWNER TO hospital_routine_owner;

ALTER FUNCTION hospital.cancel_appointment(bigint, bigint)
    OWNER TO hospital_routine_owner;

ALTER FUNCTION hospital.reschedule_appointment(bigint, bigint, bigint)
    OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

-- Execute using the restricted function owner's permissions.
ALTER FUNCTION hospital.book_appointment(bigint, bigint, text)
    SECURITY DEFINER;

ALTER FUNCTION hospital.cancel_appointment(bigint, bigint)
    SECURITY DEFINER;

ALTER FUNCTION hospital.reschedule_appointment(bigint, bigint, bigint)
    SECURITY DEFINER;

-- Use trusted schemas, with the temporary schema last.
ALTER FUNCTION hospital.book_appointment(bigint, bigint, text)
    SET search_path = pg_catalog, hospital, pg_temp;

ALTER FUNCTION hospital.cancel_appointment(bigint, bigint)
    SET search_path = pg_catalog, hospital, pg_temp;

ALTER FUNCTION hospital.reschedule_appointment(bigint, bigint, bigint)
    SET search_path = pg_catalog, hospital, pg_temp;

REVOKE ALL ON FUNCTION
    hospital.book_appointment(bigint, bigint, text),
    hospital.cancel_appointment(bigint, bigint),
    hospital.reschedule_appointment(bigint, bigint, bigint)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    hospital.book_appointment(bigint, bigint, text),
    hospital.cancel_appointment(bigint, bigint),
    hospital.reschedule_appointment(bigint, bigint, bigint)
TO hospital_app;

COMMIT;