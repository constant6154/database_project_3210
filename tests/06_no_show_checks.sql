BEGIN;

DO $$
DECLARE
    v_start timestamptz;
    v_slot_id bigint;
    v_appointment_id bigint;
    v_result boolean;
BEGIN
    -- Choose a time before all existing slots for doctor 1.
    SELECT LEAST(
        COALESCE(MIN(starts_at), clock_timestamp()),
        clock_timestamp()
    ) - interval '2 days'
    INTO v_start
    FROM hospital.appointment_slots
    WHERE doctor_id = 1;

    INSERT INTO hospital.appointment_slots (
        doctor_id, starts_at, ends_at
    )
    VALUES (
        1, v_start, v_start + interval '30 minutes'
    )
    RETURNING slot_id INTO v_slot_id;

    -- Direct insertion is only for this past test fixture.
    INSERT INTO hospital.appointments (
        patient_id, slot_id, status, booked_fee, reason
    )
    VALUES (
        2, v_slot_id, 'Booked', 800, 'No-show test'
    )
    RETURNING appointment_id INTO v_appointment_id;

    BEGIN
        PERFORM hospital.mark_no_show(2, v_appointment_id);
        RAISE EXCEPTION 'FAIL: wrong doctor was accepted';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM <> 'Appointment belongs to another doctor' THEN
                RAISE;
            END IF;
            RAISE NOTICE 'PASS 1: wrong doctor rejected';
    END;

    v_result := hospital.mark_no_show(1, v_appointment_id);

    IF v_result IS DISTINCT FROM true
       OR NOT EXISTS (
           SELECT 1
           FROM hospital.appointments
           WHERE appointment_id = v_appointment_id
             AND status = 'NoShow'
       ) THEN
        RAISE EXCEPTION 'FAIL: NoShow status was not saved';
    END IF;

    RAISE NOTICE 'PASS 2: past appointment marked NoShow';

    v_result := hospital.mark_no_show(1, v_appointment_id);

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL: repeated action should return false';
    END IF;

    RAISE NOTICE 'PASS 3: repeated action returns false';

    IF (
        SELECT count(*)
        FROM hospital.appointment_audit
        WHERE appointment_id = v_appointment_id
          AND action = 'UPDATE'
          AND old_values ->> 'status' = 'Booked'
          AND new_values ->> 'status' = 'NoShow'
    ) <> 1 THEN
        RAISE EXCEPTION 'FAIL: expected exactly one NoShow audit entry';
    END IF;

    RAISE NOTICE 'PASS 4: status change audited exactly once';
END;
$$;

ROLLBACK;