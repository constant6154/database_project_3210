BEGIN;

CREATE OR REPLACE FUNCTION hospital.mark_no_show(
    p_doctor_id bigint,
    p_appointment_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_id bigint;
    v_slot_id bigint;
    v_slot hospital.appointment_slots%ROWTYPE;
    v_appointment hospital.appointments%ROWTYPE;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Use READ COMMITTED isolation';
    END IF;

    IF p_doctor_id IS NULL OR p_appointment_id IS NULL THEN
        RAISE EXCEPTION 'Doctor and appointment IDs are required';
    END IF;

    SELECT a.patient_id, a.slot_id
    INTO v_patient_id, v_slot_id
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found';
    END IF;

    -- Same lock order as our other appointment operations:
    -- patient, slot, appointment.
    PERFORM p.patient_id
    FROM hospital.patients AS p
    WHERE p.patient_id = v_patient_id
    FOR UPDATE;

    SELECT s.*
    INTO v_slot
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id = v_slot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment slot not found';
    END IF;

    SELECT a.*
    INTO v_appointment
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found';
    END IF;

    IF v_appointment.patient_id <> v_patient_id
       OR v_appointment.slot_id <> v_slot_id THEN
        RAISE EXCEPTION 'Appointment changed; retry the operation';
    END IF;

    IF v_slot.doctor_id <> p_doctor_id THEN
        RAISE EXCEPTION 'Appointment belongs to another doctor';
    END IF;

    PERFORM d.doctor_id
    FROM hospital.doctors AS d
    JOIN hospital.users AS u ON u.user_id = d.user_id
    WHERE d.doctor_id = p_doctor_id
      AND u.is_active
    FOR SHARE OF d, u;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor does not exist or is inactive';
    END IF;

    IF v_appointment.status = 'NoShow' THEN
        RETURN false;
    END IF;

    IF v_appointment.status <> 'Booked' THEN
        RAISE EXCEPTION 'Only booked appointments can become NoShow';
    END IF;

    IF v_slot.ends_at > clock_timestamp() THEN
        RAISE EXCEPTION 'Appointment slot has not ended yet';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM hospital.consultations AS c
        WHERE c.appointment_id = p_appointment_id
    ) THEN
        RAISE EXCEPTION 'Appointment already has a consultation';
    END IF;

    UPDATE hospital.appointments
    SET status = 'NoShow'
    WHERE appointment_id = p_appointment_id;

    RETURN true;
END;
$$;

COMMIT;