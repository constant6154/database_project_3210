BEGIN ISOLATION LEVEL READ COMMITTED;

DO $$
DECLARE
    v_rejected boolean;
BEGIN
    -- Test 1: slot 1 already has an active booking.
    v_rejected := false;

    BEGIN
        PERFORM hospital.book_appointment(
            2, 1, 'Duplicate booking test'
        );
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Slot is already booked' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: duplicate booking was accepted';
    END IF;

    RAISE NOTICE 'PASS 1: duplicate booking rejected';

    -- Test 2: patient 1 already has slot 1, 09:00–09:30.
    -- Slot 5 belongs to another doctor at the same time.
    v_rejected := false;

    BEGIN
        PERFORM hospital.book_appointment(
            1, 5, 'Patient overlap test'
        );
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Patient already has an overlapping appointment' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: overlapping appointment was accepted';
    END IF;

    RAISE NOTICE 'PASS 2: patient overlap rejected';
END;
$$;

ROLLBACK;

SELECT
    (SELECT count(*) FROM hospital.appointments)
        AS total_appointments,
    (SELECT count(*) FROM hospital.available_slots)
        AS available_slots;