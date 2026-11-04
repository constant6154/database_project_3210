BEGIN ISOLATION LEVEL READ COMMITTED;

DO $$
DECLARE
    v_new_id bigint;
    v_rejected boolean := false;
    v_audit_before bigint;
BEGIN
    SELECT count(*) INTO v_audit_before
    FROM hospital.appointment_audit;

    -- Slot 2 is occupied. Rescheduling to it must fail.
    BEGIN
        PERFORM hospital.reschedule_appointment(1, 1, 2);
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Slot is already booked' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: occupied replacement slot accepted';
    END IF;

    -- The attempted cancellation must have been undone.
    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments
        WHERE appointment_id = 1
          AND slot_id = 1
          AND status = 'Booked'
    ) THEN
        RAISE EXCEPTION 'FAIL: original booking was not preserved';
    END IF;

    IF (SELECT count(*) FROM hospital.appointment_audit)
       <> v_audit_before THEN
        RAISE EXCEPTION 'FAIL: failed reschedule left audit changes';
    END IF;

    RAISE NOTICE
        'PASS 1: failed reschedule preserved booking and audit history';

    -- Slot 3 should be free after cancelling appointment 11.
    v_new_id := hospital.reschedule_appointment(1, 1, 3);

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments
        WHERE appointment_id = 1
          AND status = 'Cancelled'
    ) THEN
        RAISE EXCEPTION 'FAIL: old booking was not cancelled';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments
        WHERE appointment_id = v_new_id
          AND patient_id = 1
          AND slot_id = 3
          AND status = 'Booked'
    ) THEN
        RAISE EXCEPTION 'FAIL: replacement booking missing';
    END IF;

    RAISE NOTICE
        'PASS 2: successful reschedule cancelled old and created new booking';
END;
$$;

-- Restore the state from before these tests.
ROLLBACK;

SELECT
    (SELECT status FROM hospital.appointments
     WHERE appointment_id = 1) AS original_status,
    (SELECT count(*) FROM hospital.appointments) AS total_appointments,
    (SELECT count(*) FROM hospital.available_slots) AS available_slots;