BEGIN;

DO $$
DECLARE
    v_start timestamptz;
    v_slot_id bigint;
    v_appointment_id bigint;
    v_result boolean;
BEGIN
    -- Choose a time beyond all existing slots.
    SELECT GREATEST(
        COALESCE(MAX(ends_at), clock_timestamp()),
        clock_timestamp()
    ) + interval '2 days'
    INTO v_start
    FROM hospital.appointment_slots;

    INSERT INTO hospital.appointment_slots (
        doctor_id, starts_at, ends_at
    )
    VALUES (
        1, v_start, v_start + interval '30 minutes'
    )
    RETURNING slot_id INTO v_slot_id;

    BEGIN
        PERFORM hospital.set_slot_blocked(2, v_slot_id, true);
        RAISE EXCEPTION 'FAIL: wrong doctor accepted';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM <> 'Slot belongs to another doctor' THEN
                RAISE;
            END IF;
    END;

    RAISE NOTICE 'PASS 1: wrong doctor rejected';

    v_result := hospital.set_slot_blocked(1, v_slot_id, true);

    IF v_result IS DISTINCT FROM true
       OR NOT EXISTS (
           SELECT 1
           FROM hospital.appointment_slots
           WHERE slot_id = v_slot_id AND is_blocked
       )
       OR EXISTS (
           SELECT 1
           FROM hospital.available_slots
           WHERE slot_id = v_slot_id
       ) THEN
        RAISE EXCEPTION 'FAIL: slot was not blocked and hidden';
    END IF;

    RAISE NOTICE 'PASS 2: blocked slot hidden from availability';

    v_result := hospital.set_slot_blocked(1, v_slot_id, true);

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL: repeated blocking should return false';
    END IF;

    RAISE NOTICE 'PASS 3: repeated blocking returns false';

    v_result := hospital.set_slot_blocked(1, v_slot_id, false);

    IF v_result IS DISTINCT FROM true
       OR NOT EXISTS (
           SELECT 1
           FROM hospital.available_slots
           WHERE slot_id = v_slot_id
       ) THEN
        RAISE EXCEPTION 'FAIL: slot was not made available again';
    END IF;

    RAISE NOTICE 'PASS 4: unblocked slot available again';

    v_appointment_id := hospital.book_appointment(
        2, v_slot_id, 'Slot blocking test'
    );

    BEGIN
        PERFORM hospital.set_slot_blocked(1, v_slot_id, true);
        RAISE EXCEPTION 'FAIL: occupied slot was blocked';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM <> 'Cannot block an occupied slot' THEN
                RAISE;
            END IF;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments
        WHERE appointment_id = v_appointment_id
          AND status = 'Booked'
    ) OR EXISTS (
        SELECT 1
        FROM hospital.appointment_slots
        WHERE slot_id = v_slot_id AND is_blocked
    ) THEN
        RAISE EXCEPTION 'FAIL: existing booking was disrupted';
    END IF;

    RAISE NOTICE 'PASS 5: occupied slot protected; booking preserved';
END;
$$;

ROLLBACK;