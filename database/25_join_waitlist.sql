BEGIN;

-- The internal routine owner needs to create a request and return its ID.
GRANT INSERT (original_appointment_id, earliest_date, latest_date),
      SELECT (request_id, original_appointment_id, status)
ON hospital.waitlist_requests TO hospital_routine_owner;

CREATE OR REPLACE FUNCTION hospital.join_waitlist(
    p_patient_id bigint,
    p_appointment_id bigint,
    p_earliest_date date,
    p_latest_date date
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
DECLARE
    v_user_id bigint;
    v_status varchar;
    v_original_start timestamptz;
    v_today date;
    v_original_date date;
    v_request_id bigint;
BEGIN
    IF p_patient_id IS NULL OR p_appointment_id IS NULL
       OR p_earliest_date IS NULL OR p_latest_date IS NULL THEN
        RAISE EXCEPTION 'Patient, appointment and both dates are required';
    END IF;

    -- Follow the patient-first lock order used by booking and cancellation.
    SELECT p.user_id INTO v_user_id
    FROM hospital.patients AS p
    WHERE p.patient_id = p_patient_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient account is unavailable';
    END IF;

    PERFORM 1
    FROM hospital.users AS u
    WHERE u.user_id = v_user_id AND u.is_active
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient account is unavailable';
    END IF;

    -- Ownership and status are checked against the actual booking.
    SELECT a.status, s.starts_at INTO v_status, v_original_start
    FROM hospital.appointments AS a
    JOIN hospital.appointment_slots AS s ON s.slot_id = a.slot_id
    WHERE a.appointment_id = p_appointment_id
      AND a.patient_id = p_patient_id
    FOR UPDATE OF a;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment is unavailable for this patient';
    END IF;

    IF v_status <> 'Booked' OR v_original_start <= clock_timestamp() THEN
        RAISE EXCEPTION 'Only a future booked appointment can join the waitlist';
    END IF;

    v_today := (clock_timestamp() AT TIME ZONE 'Asia/Dhaka')::date;
    v_original_date := (v_original_start AT TIME ZONE 'Asia/Dhaka')::date;

    IF p_earliest_date < v_today
       OR p_latest_date < p_earliest_date
       OR p_latest_date >= v_original_date THEN
        RAISE EXCEPTION
            'Choose dates from today through the day before your booked visit';
    END IF;

    INSERT INTO hospital.waitlist_requests (
        original_appointment_id, earliest_date, latest_date
    )
    VALUES (p_appointment_id, p_earliest_date, p_latest_date)
    ON CONFLICT (original_appointment_id) WHERE status = 'Active'
    DO NOTHING
    RETURNING request_id INTO v_request_id;

    IF v_request_id IS NULL THEN
        RAISE EXCEPTION 'This appointment already has an active waitlist request';
    END IF;

    RETURN v_request_id;
END;
$$;

GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER FUNCTION hospital.join_waitlist(bigint, bigint, date, date)
    OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.join_waitlist(bigint, bigint, date, date)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION hospital.join_waitlist(bigint, bigint, date, date)
    TO hospital_app;

COMMIT;