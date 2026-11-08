BEGIN;

GRANT SELECT (earliest_date, latest_date)
ON hospital.waitlist_requests TO hospital_routine_owner;

CREATE OR REPLACE FUNCTION hospital.patient_active_waitlist(p_user_id bigint)
RETURNS TABLE (
    original_appointment_id bigint,
    request_id bigint,
    earliest_date date,
    latest_date date
)
LANGUAGE sql
STABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
    SELECT w.original_appointment_id, w.request_id,
           w.earliest_date, w.latest_date
    FROM hospital.waitlist_requests AS w
    JOIN hospital.appointments AS a
      ON a.appointment_id = w.original_appointment_id
    JOIN hospital.patients AS p ON p.patient_id = a.patient_id
    JOIN hospital.users AS u ON u.user_id = p.user_id
    WHERE u.user_id = p_user_id
      AND u.is_active
      AND a.status = 'Booked'
      AND w.status = 'Active';
$$;

GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER FUNCTION hospital.patient_active_waitlist(bigint)
    OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.patient_active_waitlist(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.patient_active_waitlist(bigint)
    TO hospital_app;

COMMIT;