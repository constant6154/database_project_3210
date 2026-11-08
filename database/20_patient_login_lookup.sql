BEGIN;

-- The internal function owner needs these columns for the lookup.
-- The website's hospital_app role receives only permission to call it.
GRANT SELECT (user_id, email, role, is_active, password_hash)
ON hospital.users TO hospital_routine_owner;

GRANT SELECT (user_id, patient_id, full_name)
ON hospital.patients TO hospital_routine_owner;

CREATE OR REPLACE FUNCTION hospital.lookup_patient_login(p_email text)
RETURNS TABLE (
    user_id bigint,
    patient_id bigint,
    full_name varchar,
    password_hash text
)
LANGUAGE sql
STABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
    SELECT u.user_id, p.patient_id, p.full_name, u.password_hash
    FROM hospital.users AS u
    JOIN hospital.patients AS p ON p.user_id = u.user_id
    WHERE u.email = lower(btrim(p_email))
      AND u.role = 'Patient'
      AND u.is_active
      AND u.password_hash <> '!';
$$;

GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER FUNCTION hospital.lookup_patient_login(text)
    OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.lookup_patient_login(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.lookup_patient_login(text) TO hospital_app;

COMMIT;
