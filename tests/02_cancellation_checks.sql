BEGIN ISOLATION LEVEL READ COMMITTED;

DO $$
DECLARE
    v_new_id bigint;
    v_rejected boolean := false;
BEGIN
    -- Another patient must not cancel patient 1's appointment.
    BEGIN
        PERFORM hospital.cancel_appointment(2, 1);
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Appointment does not belong to this patient' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: another patient cancelled the appointment';
    END IF;

    RAISE NOTICE 'PASS 1: wrong-patient cancellation rejected';

    -- Cancel the original booking.
    IF hospital.cancel_appointment(1, 1) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: cancellation did not succeed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments
        WHERE appointment_id = 1
          AND status = 'Cancelled'
    ) THEN
        RAISE EXCEPTION 'FAIL: cancelled booking history was not retained';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM hospital.available_slots WHERE slot_id = 1
    ) THEN
        RAISE EXCEPTION 'FAIL: cancelled slot did not become available';
    END IF;

    RAISE NOTICE 'PASS 2: history retained and slot released';

    -- Repeating cancellation should return false.
    IF hospital.cancel_appointment(1, 1) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL: repeated cancellation returned wrong result';
    END IF;

    RAISE NOTICE 'PASS 3: repeated cancellation handled safely';

    -- Patient 2 takes the freed slot.
    v_new_id := hospital.book_appointment(
        2, 1, 'Rebooking a cancelled slot'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments
        WHERE appointment_id = v_new_id
          AND patient_id = 2
          AND slot_id = 1
          AND status = 'Booked'
    ) THEN
        RAISE EXCEPTION 'FAIL: replacement booking missing';
    END IF;

    IF EXISTS (
        SELECT 1 FROM hospital.available_slots WHERE slot_id = 1
    ) THEN
        RAISE EXCEPTION 'FAIL: rebooked slot still appears available';
    END IF;

    RAISE NOTICE 'PASS 4: freed slot successfully rebooked';
END;
$$;

-- Undo all test changes.
ROLLBACK;

SELECT
    (SELECT status FROM hospital.appointments
     WHERE appointment_id = 1) AS original_status,
    (SELECT count(*) FROM hospital.appointments) AS total_appointments,
    (SELECT count(*) FROM hospital.available_slots) AS available_slots;