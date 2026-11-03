BEGIN;

CREATE OR REPLACE FUNCTION hospital.cancel_appointment(
    p_patient_id bigint,
    p_appointment_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_slot_id bigint;
    v_starts_at timestamptz;
    v_appointment hospital.appointments%ROWTYPE;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Cancellation requires READ COMMITTED isolation';
    END IF;

    IF p_patient_id IS NULL OR p_appointment_id IS NULL THEN
        RAISE EXCEPTION 'Patient ID and appointment ID are required';
    END IF;

    -- Follow the same patient-first lock order as booking.
    PERFORM 1
    FROM hospital.patients
    WHERE patient_id = p_patient_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient does not exist';
    END IF;

    SELECT a.slot_id
    INTO v_slot_id
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id
      AND a.patient_id = p_patient_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment does not belong to this patient';
    END IF;

    -- Lock the slot before changing its booking.
    SELECT s.starts_at
    INTO v_starts_at
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id = v_slot_id
    FOR UPDATE;

    SELECT a.*
    INTO v_appointment
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id
    FOR UPDATE;

    -- Recheck after acquiring the locks.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment no longer exists';
    END IF;

    IF v_appointment.patient_id <> p_patient_id
       OR v_appointment.slot_id <> v_slot_id THEN
        RAISE EXCEPTION 'Appointment changed; retry cancellation';
    END IF;

    -- Repeated cancellation is harmless.
    IF v_appointment.status = 'Cancelled' THEN
        RETURN false;
    END IF;

    IF v_appointment.status <> 'Booked' THEN
        RAISE EXCEPTION 'Only booked appointments can be cancelled';
    END IF;

    IF v_starts_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Cannot cancel an appointment that has started';
    END IF;

    UPDATE hospital.appointments
    SET status = 'Cancelled',
        updated_at = clock_timestamp()
    WHERE appointment_id = p_appointment_id;

    RETURN true;
END;
$$;

COMMIT;