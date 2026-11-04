BEGIN;

CREATE OR REPLACE PROCEDURE hospital.complete_consultation(
    p_doctor_id bigint,
    p_appointment_id bigint,
    p_diagnosis text,
    p_notes text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_patient_id bigint;
    v_slot_id bigint;
    v_slot hospital.appointment_slots%ROWTYPE;
    v_appointment hospital.appointments%ROWTYPE;
    v_active boolean;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Completion requires READ COMMITTED isolation';
    END IF;

    IF p_doctor_id IS NULL OR p_appointment_id IS NULL THEN
        RAISE EXCEPTION 'Doctor and appointment IDs are required';
    END IF;

    IF p_diagnosis IS NULL OR btrim(p_diagnosis) = '' THEN
        RAISE EXCEPTION 'Diagnosis is required';
    END IF;

    SELECT a.patient_id, a.slot_id
    INTO v_patient_id, v_slot_id
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment does not exist';
    END IF;

    -- Follow patient -> slot -> appointment lock order.
    PERFORM 1
    FROM hospital.patients
    WHERE patient_id = v_patient_id
    FOR UPDATE;

    SELECT s.*
    INTO v_slot
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id = v_slot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment slot does not exist';
    END IF;

    SELECT a.*
    INTO v_appointment
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment no longer exists';
    END IF;

    IF v_appointment.patient_id <> v_patient_id
       OR v_appointment.slot_id <> v_slot_id THEN
        RAISE EXCEPTION 'Appointment changed; retry completion';
    END IF;

    IF v_slot.doctor_id <> p_doctor_id THEN
        RAISE EXCEPTION 'Appointment is assigned to another doctor';
    END IF;

    SELECT u.is_active
    INTO v_active
    FROM hospital.doctors AS d
    JOIN hospital.users AS u ON u.user_id = d.user_id
    WHERE d.doctor_id = p_doctor_id
    FOR SHARE OF d, u;

    IF v_active IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Doctor account is inactive';
    END IF;

    IF v_appointment.status <> 'Booked' THEN
        RAISE EXCEPTION 'Only booked appointments can be completed';
    END IF;

    IF v_slot.starts_at > clock_timestamp() THEN
        RAISE EXCEPTION 'Appointment has not started yet';
    END IF;

    INSERT INTO hospital.consultations (
        appointment_id, diagnosis, clinical_notes, completed_at
    )
    VALUES (
        p_appointment_id,
        btrim(p_diagnosis),
        NULLIF(btrim(p_notes), ''),
        clock_timestamp()
    );

    UPDATE hospital.appointments
    SET status = 'Completed'
    WHERE appointment_id = p_appointment_id;
END;
$$;

COMMIT;