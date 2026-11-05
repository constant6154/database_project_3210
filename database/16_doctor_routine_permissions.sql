BEGIN;

-- Additional permissions needed inside the routines.
GRANT SELECT ON
    hospital.doctor_schedules,
    hospital.consultations
TO hospital_routine_owner;

GRANT UPDATE (schedule_id)
ON hospital.doctor_schedules TO hospital_routine_owner;

GRANT INSERT ON
    hospital.appointment_slots,
    hospital.consultations
TO hospital_routine_owner;

GRANT UPDATE (is_blocked)
ON hospital.appointment_slots TO hospital_routine_owner;

-- Identity sequences used by slot and consultation insertion.
DO $$
DECLARE
    v_sequence text;
BEGIN
    v_sequence := pg_get_serial_sequence(
        'hospital.appointment_slots', 'slot_id'
    );

    EXECUTE format(
        'GRANT USAGE ON SEQUENCE %s TO hospital_routine_owner',
        v_sequence
    );

    v_sequence := pg_get_serial_sequence(
        'hospital.consultations', 'consultation_id'
    );

    EXECUTE format(
        'GRANT USAGE ON SEQUENCE %s TO hospital_routine_owner',
        v_sequence
    );
END;
$$;

GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER PROCEDURE hospital.complete_consultation(bigint, bigint, text, text)
    OWNER TO hospital_routine_owner;

ALTER FUNCTION hospital.mark_no_show(bigint, bigint)
    OWNER TO hospital_routine_owner;

ALTER FUNCTION hospital.generate_slots(bigint, date, date)
    OWNER TO hospital_routine_owner;

ALTER FUNCTION hospital.set_slot_blocked(bigint, bigint, boolean)
    OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

ALTER PROCEDURE hospital.complete_consultation(bigint, bigint, text, text)
    SECURITY DEFINER;

ALTER FUNCTION hospital.mark_no_show(bigint, bigint)
    SECURITY DEFINER;

ALTER FUNCTION hospital.generate_slots(bigint, date, date)
    SECURITY DEFINER;

ALTER FUNCTION hospital.set_slot_blocked(bigint, bigint, boolean)
    SECURITY DEFINER;

ALTER PROCEDURE hospital.complete_consultation(bigint, bigint, text, text)
    SET search_path = pg_catalog, hospital, pg_temp;

ALTER FUNCTION hospital.mark_no_show(bigint, bigint)
    SET search_path = pg_catalog, hospital, pg_temp;

ALTER FUNCTION hospital.generate_slots(bigint, date, date)
    SET search_path = pg_catalog, hospital, pg_temp;

ALTER FUNCTION hospital.set_slot_blocked(bigint, bigint, boolean)
    SET search_path = pg_catalog, hospital, pg_temp;

REVOKE ALL ON PROCEDURE
    hospital.complete_consultation(bigint, bigint, text, text)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    hospital.mark_no_show(bigint, bigint),
    hospital.generate_slots(bigint, date, date),
    hospital.set_slot_blocked(bigint, bigint, boolean)
FROM PUBLIC;

GRANT EXECUTE ON PROCEDURE
    hospital.complete_consultation(bigint, bigint, text, text)
TO hospital_app;

GRANT EXECUTE ON FUNCTION
    hospital.mark_no_show(bigint, bigint),
    hospital.generate_slots(bigint, date, date),
    hospital.set_slot_blocked(bigint, bigint, boolean)
TO hospital_app;

COMMIT;