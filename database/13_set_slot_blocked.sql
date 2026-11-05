BEGIN;

CREATE OR REPLACE FUNCTION hospital.set_slot_blocked(
    p_doctor_id bigint,
    p_slot_id bigint,
    p_blocked boolean
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_slot hospital.appointment_slots%ROWTYPE;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Use READ COMMITTED isolation';
    END IF;

    IF p_doctor_id IS NULL
       OR p_slot_id IS NULL
       OR p_blocked IS NULL THEN
        RAISE EXCEPTION 'Doctor, slot and blocked state are required';
    END IF;

    -- Booking also locks this row, so booking and blocking
    -- cannot change the same slot simultaneously.
    SELECT s.*
    INTO v_slot
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id = p_slot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slot not found';
    END IF;

    IF v_slot.doctor_id <> p_doctor_id THEN
        RAISE EXCEPTION 'Slot belongs to another doctor';
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

    IF v_slot.starts_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Only future slots can be changed';
    END IF;

    IF p_blocked AND EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        WHERE a.slot_id = p_slot_id
          AND a.status <> 'Cancelled'
    ) THEN
        RAISE EXCEPTION 'Cannot block an occupied slot';
    END IF;

    IF v_slot.is_blocked = p_blocked THEN
        RETURN false;
    END IF;

    UPDATE hospital.appointment_slots
    SET is_blocked = p_blocked
    WHERE slot_id = p_slot_id;

    RETURN true;
END;
$$;

COMMIT;