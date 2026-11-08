BEGIN;

CREATE OR REPLACE FUNCTION hospital.patient_appointments(p_user_id bigint)
RETURNS TABLE (
    appointment_id bigint,
    doctor_name varchar,
    department varchar,
    starts_at timestamptz,
    ends_at timestamptz,
    status varchar,
    booked_fee numeric
)
LANGUAGE sql
STABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
    SELECT
        a.appointment_id,
        d.full_name,
        dep.name,
        s.starts_at,
        s.ends_at,
        a.status,
        a.booked_fee
    FROM hospital.users AS u
    JOIN hospital.patients AS p ON p.user_id = u.user_id
    JOIN hospital.appointments AS a ON a.patient_id = p.patient_id
    JOIN hospital.appointment_slots AS s ON s.slot_id = a.slot_id
    JOIN hospital.doctors AS d ON d.doctor_id = s.doctor_id
    JOIN hospital.departments AS dep ON dep.department_id = d.department_id
    WHERE u.user_id = p_user_id
      AND u.is_active
    ORDER BY s.starts_at DESC, a.appointment_id DESC;
$$;

-- Earlier migrations granted the routine owner access to the other tables.
GRANT SELECT (department_id, name)
ON hospital.departments TO hospital_routine_owner;

GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER FUNCTION hospital.patient_appointments(bigint)
    OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.patient_appointments(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.patient_appointments(bigint) TO hospital_app;

COMMIT;