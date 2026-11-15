BEGIN;

CREATE OR REPLACE FUNCTION hospital.lookup_staff_login(p_email text)
RETURNS TABLE (user_id bigint, email text, password_hash text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT u.user_id, u.email::text, u.password_hash::text
    FROM hospital.users AS u
    WHERE u.role = 'Admin' AND u.is_active
      AND lower(u.email) = lower(trim(p_email));
$$;

ALTER FUNCTION hospital.lookup_staff_login(text) OWNER TO hospital_routine_owner;
REVOKE ALL ON FUNCTION hospital.lookup_staff_login(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.lookup_staff_login(text) TO hospital_app;

COMMIT;
