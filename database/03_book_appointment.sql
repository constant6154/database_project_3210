BEGIN;

CREATE OR REPLACE FUNCTION hospital.book_appointment(
    p_patient_id bigint,
    p_slot_id bigint,
    p_reason text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_patient_user_id bigint;
    v_active boolean;
    v_slot hospital.appointment_slots%ROWTYPE;
    v_fee numeric(10,2);
    v_appointment_id bigint;
BEGIN
    -- This locking strategy uses Read Committed isolation.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Booking requires READ COMMITTED isolation';
    END IF;

    IF p_patient_id IS NULL OR p_slot_id IS NULL THEN
        RAISE EXCEPTION 'Patient ID and slot ID are required';
    END IF;

    IF char_length(btrim(p_reason)) > 255 THEN
        RAISE EXCEPTION 'Reason must be at most 255 characters';
    END IF;

    -- Serialize booking requests for the same patient.
    SELECT p.user_id
    INTO v_patient_user_id
    FROM hospital.patients AS p
    WHERE p.patient_id = p_patient_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient does not exist';
    END IF;

    -- Keep the patient's account status stable until transaction end.
    SELECT u.is_active
    INTO v_active
    FROM hospital.users AS u
    WHERE u.user_id = v_patient_user_id
    FOR SHARE;

    IF v_active IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Patient account is inactive';
    END IF;

    -- Serialize requests for the same slot.
    SELECT s.*
    INTO v_slot
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id = p_slot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slot does not exist';
    END IF;

    IF v_slot.is_blocked THEN
        RAISE EXCEPTION 'Slot is blocked';
    END IF;

    -- Lock doctor fee and account status while creating the booking.
    SELECT d.consultation_fee, u.is_active
    INTO v_fee, v_active
    FROM hospital.doctors AS d
    JOIN hospital.users AS u ON u.user_id = d.user_id
    WHERE d.doctor_id = v_slot.doctor_id
    FOR SHARE OF d, u;

    IF v_active IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Doctor account is inactive';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        WHERE a.slot_id = p_slot_id
          AND a.status <> 'Cancelled'
    ) THEN
        RAISE EXCEPTION 'Slot is already booked';
    END IF;

    -- Overlap: existing start < new end AND existing end > new start.
    IF EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        JOIN hospital.appointment_slots AS s
            ON s.slot_id = a.slot_id
        WHERE a.patient_id = p_patient_id
          AND a.status <> 'Cancelled'
          AND s.starts_at < v_slot.ends_at
          AND s.ends_at > v_slot.starts_at
    ) THEN
        RAISE EXCEPTION
            'Patient already has an overlapping appointment';
    END IF;

    -- Use actual current time, including time spent waiting for locks.
    IF v_slot.starts_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Cannot book a slot that has already started';
    END IF;

    INSERT INTO hospital.appointments (
        patient_id, slot_id, status, reason, booked_fee
    )
    VALUES (
        p_patient_id,
        p_slot_id,
        'Booked',
        NULLIF(btrim(p_reason), ''),
        v_fee
    )
    RETURNING appointment_id INTO v_appointment_id;

    RETURN v_appointment_id;
END;
$$;

COMMIT;