BEGIN;

SET LOCAL ROLE hospital_app;

DO $$
DECLARE
    v_slots bigint[];
    v_appointment_id bigint;
    v_new_appointment_id bigint;
    v_result boolean;
BEGIN
    IF current_user <> 'hospital_app' THEN
        RAISE EXCEPTION 'FAIL: test must run as hospital_app';
    END IF;

    -- Select two future slots for the same doctor.
    SELECT array_agg(slot_id ORDER BY starts_at, slot_id)
    INTO v_slots
    FROM (
        SELECT slot_id, starts_at
        FROM hospital.available_slots
        WHERE doctor_id = 1
          AND starts_at > clock_timestamp() + interval '1 hour'
        ORDER BY starts_at, slot_id
        LIMIT 2
    ) AS candidate_slots;

    IF COALESCE(array_length(v_slots, 1), 0) < 2 THEN
        RAISE EXCEPTION
            'Test needs two available future slots for doctor 1';
    END IF;

    v_appointment_id := hospital.book_appointment(
        2, v_slots[1], 'Application permission test'
    );

    IF v_appointment_id IS NULL OR EXISTS (
        SELECT 1
        FROM hospital.available_slots
        WHERE slot_id = v_slots[1]
    ) THEN
        RAISE EXCEPTION 'FAIL: booking did not occupy the slot';
    END IF;

    RAISE NOTICE 'PASS 1: hospital_app can book through the function';

    v_new_appointment_id := hospital.reschedule_appointment(
        2, v_appointment_id, v_slots[2]
    );

    IF v_new_appointment_id IS NULL
       OR v_new_appointment_id = v_appointment_id
       OR NOT EXISTS (
           SELECT 1 FROM hospital.available_slots
           WHERE slot_id = v_slots[1]
       )
       OR EXISTS (
           SELECT 1 FROM hospital.available_slots
           WHERE slot_id = v_slots[2]
       ) THEN
        RAISE EXCEPTION 'FAIL: rescheduling did not move the booking';
    END IF;

    RAISE NOTICE 'PASS 2: hospital_app can reschedule';

    v_result := hospital.cancel_appointment(
        2, v_new_appointment_id
    );

    IF v_result IS DISTINCT FROM true
       OR NOT EXISTS (
           SELECT 1 FROM hospital.available_slots
           WHERE slot_id = v_slots[2]
       ) THEN
        RAISE EXCEPTION 'FAIL: cancellation did not release the slot';
    END IF;

    RAISE NOTICE 'PASS 3: hospital_app can cancel';

    BEGIN
        UPDATE hospital.appointments
        SET status = 'Cancelled'
        WHERE false;

        RAISE EXCEPTION 'FAIL: direct UPDATE was allowed';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'PASS 4: direct appointment updates denied';
    END;

    BEGIN
        PERFORM user_id FROM hospital.users LIMIT 1;

        RAISE EXCEPTION 'FAIL: direct users access was allowed';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'PASS 5: direct users access denied';
    END;
END;
$$;

ROLLBACK;