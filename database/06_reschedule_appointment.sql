BEGIN;

CREATE OR REPLACE FUNCTION hospital.reschedule_appointment(
    p_patient_id bigint,
    p_appointment_id bigint,
    p_new_slot_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_old_slot_id bigint;
    v_old_reason text;
    v_new_appointment_id bigint;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Rescheduling requires READ COMMITTED isolation';
    END IF;

    IF p_patient_id IS NULL
       OR p_appointment_id IS NULL
       OR p_new_slot_id IS NULL THEN
        RAISE EXCEPTION 'Patient, appointment and new slot IDs are required';
    END IF;

    -- Use the same patient-first locking order as booking/cancellation.
    PERFORM 1
    FROM hospital.patients
    WHERE patient_id = p_patient_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient does not exist';
    END IF;

    SELECT a.slot_id, a.reason
    INTO v_old_slot_id, v_old_reason
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id
      AND a.patient_id = p_patient_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment does not belong to this patient';
    END IF;

    IF v_old_slot_id = p_new_slot_id THEN
        RAISE EXCEPTION 'Choose a different slot';
    END IF;

    -- Lock both slots in ascending order to reduce deadlock risk.
    PERFORM s.slot_id
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id IN (v_old_slot_id, p_new_slot_id)
    ORDER BY s.slot_id
    FOR UPDATE;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointment_slots
        WHERE slot_id = p_new_slot_id
    ) THEN
        RAISE EXCEPTION 'New slot does not exist';
    END IF;

    IF hospital.cancel_appointment(
        p_patient_id, p_appointment_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Cannot reschedule a cancelled appointment';
    END IF;

    v_new_appointment_id := hospital.book_appointment(
        p_patient_id,
        p_new_slot_id,
        v_old_reason
    );

    -- If booking raises an error, the cancellation also rolls back.
    RETURN v_new_appointment_id;
END;
$$;

COMMIT;