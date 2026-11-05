BEGIN;

CREATE OR REPLACE FUNCTION hospital.register_patient(
    p_email text,
    p_password_hash text,
    p_full_name text,
    p_phone text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
DECLARE
    v_email text := lower(btrim(p_email));
    v_name text := btrim(p_full_name);
    v_phone text := btrim(p_phone);
    v_user_id bigint;
BEGIN
    -- Validate basic account information.
    IF v_email IS NULL
       OR length(v_email) > 254
       OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    THEN
        RAISE EXCEPTION 'Enter a valid email address'
            USING ERRCODE = '22023';
    END IF;

    IF v_name IS NULL
       OR length(v_name) NOT BETWEEN 1 AND 100
    THEN
        RAISE EXCEPTION 'Name must contain 1 to 100 characters'
            USING ERRCODE = '22023';
    END IF;

    IF v_phone IS NULL
       OR length(v_phone) NOT BETWEEN 7 AND 20
       OR v_phone !~ '^[+]?[0-9 ()-]+$'
    THEN
        RAISE EXCEPTION 'Enter a valid phone number'
            USING ERRCODE = '22023';
    END IF;

    -- Python will generate the actual scrypt password hash.
    -- This checks its expected structure, not password strength.
    IF p_password_hash IS NULL
       OR length(p_password_hash) > 512
       OR p_password_hash !~
           '^scrypt:[0-9]+:[0-9]+:[0-9]+[$][A-Za-z0-9]+[$][0-9a-f]{128}$'
    THEN
        RAISE EXCEPTION 'A valid password hash is required'
            USING ERRCODE = '22023';
    END IF;

    -- The role is fixed: public registration creates only Patients.
    INSERT INTO hospital.users (
        email,
        password_hash,
        role,
        is_active
    )
    VALUES (
        v_email,
        p_password_hash,
        'Patient',
        true
    )
    RETURNING user_id INTO v_user_id;

    -- Link the patient profile to that new account.
    INSERT INTO hospital.patients (
        user_id,
        full_name,
        phone
    )
    VALUES (
        v_user_id,
        v_name,
        v_phone
    );

    RETURN v_user_id;
END;
$$;

-- Allow the existing internal routine owner to create these records.
GRANT INSERT (email, password_hash, role, is_active)
ON hospital.users
TO hospital_routine_owner;

GRANT SELECT (user_id)
ON hospital.users
TO hospital_routine_owner;

GRANT INSERT (user_id, full_name, phone)
ON hospital.patients
TO hospital_routine_owner;

-- Grant access to the identity sequences using their actual names.
DO $$
DECLARE
    v_sequence text;
BEGIN
    v_sequence := pg_get_serial_sequence(
        'hospital.users', 'user_id'
    );

    EXECUTE format(
        'GRANT USAGE ON SEQUENCE %s TO hospital_routine_owner',
        v_sequence
    );

    v_sequence := pg_get_serial_sequence(
        'hospital.patients', 'patient_id'
    );

    EXECUTE format(
        'GRANT USAGE ON SEQUENCE %s TO hospital_routine_owner',
        v_sequence
    );
END;
$$;

-- Transfer ownership to the restricted internal role.
GRANT CREATE ON SCHEMA hospital TO hospital_routine_owner;

ALTER FUNCTION hospital.register_patient(text, text, text, text)
OWNER TO hospital_routine_owner;

REVOKE CREATE ON SCHEMA hospital FROM hospital_routine_owner;

-- Only our backend login may call this registration function.
REVOKE ALL
ON FUNCTION hospital.register_patient(text, text, text, text)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION hospital.register_patient(text, text, text, text)
TO hospital_app;

COMMIT;

-- Verify the application's permissions.
SELECT
    has_function_privilege(
        'hospital_app',
        'hospital.register_patient(text,text,text,text)',
        'EXECUTE'
    ) AS can_register_patient,

    has_table_privilege(
        'hospital_app',
        'hospital.users',
        'INSERT'
    ) AS can_insert_users_directly,

    has_table_privilege(
        'hospital_app',
        'hospital.patients',
        'INSERT'
    ) AS can_insert_patients_directly;