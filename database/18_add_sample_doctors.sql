BEGIN;

DO $$
DECLARE
    r record;
    v_department_id bigint;
    v_user_id bigint;
    v_doctor_id bigint;
    v_role text;
    v_first_date date :=
        (clock_timestamp() AT TIME ZONE 'Asia/Dhaka')::date + 1;
    v_weekday smallint;
    v_slots integer;
BEGIN
    -- Start tomorrow, using Bangladesh local time.
    v_weekday := EXTRACT(ISODOW FROM v_first_date)::smallint;

    FOR r IN
        SELECT *
        FROM (
            VALUES
                (
                    'Dermatology',
                    'Dr. Nadia Islam',
                    'nadia.islam@veya.example',
                    700.00
                ),
                (
                    'Neurology',
                    'Dr. Tanvir Hasan',
                    'tanvir.hasan@veya.example',
                    1000.00
                ),
                (
                    'Orthopedics',
                    'Dr. Imran Hossain',
                    'imran.hossain@veya.example',
                    900.00
                ),
                (
                    'Pediatrics',
                    'Dr. Samira Chowdhury',
                    'samira.chowdhury@veya.example',
                    600.00
                ),
                (
                    'ENT',
                    'Dr. Rezaul Karim',
                    'rezaul.karim@veya.example',
                    700.00
                ),
                (
                    'Ophthalmology',
                    'Dr. Nusrat Jahan',
                    'nusrat.jahan@veya.example',
                    800.00
                ),
                (
                    'Gynecology',
                    'Dr. Ayesha Siddiqua',
                    'ayesha.siddiqua@veya.example',
                    900.00
                )
        ) AS sample(department, doctor_name, email, fee)
    LOOP
        -- 1. Ensure the department exists.
        INSERT INTO hospital.departments (name)
        VALUES (r.department)
        ON CONFLICT (name) DO NOTHING;

        SELECT department_id
        INTO STRICT v_department_id
        FROM hospital.departments
        WHERE name = r.department;

        -- 2. Create a sample doctor account.
        -- '!' is an unusable password placeholder.
        -- Login credentials will be set during authentication setup.
        INSERT INTO hospital.users (
            email, password_hash, role, is_active
        )
        VALUES (
            r.email, '!', 'Doctor', true
        )
        ON CONFLICT (email) DO NOTHING;

        SELECT user_id, role
        INTO STRICT v_user_id, v_role
        FROM hospital.users
        WHERE email = r.email;

        IF v_role <> 'Doctor' THEN
            RAISE EXCEPTION
                'Account % already exists with a different role',
                r.email;
        END IF;

        -- 3. Create the doctor's professional profile.
        INSERT INTO hospital.doctors (
            user_id,
            department_id,
            full_name,
            specialization,
            consultation_fee
        )
        VALUES (
            v_user_id,
            v_department_id,
            r.doctor_name,
            r.department,
            r.fee
        )
        ON CONFLICT (user_id) DO NOTHING;

        SELECT doctor_id
        INTO STRICT v_doctor_id
        FROM hospital.doctors
        WHERE user_id = v_user_id;

        -- 4. Create one weekly session:
        -- tomorrow's weekday, 9–11 AM, 30 minutes per appointment.
        -- Skip if this doctor already has an active schedule.
        INSERT INTO hospital.doctor_schedules (
            doctor_id,
            weekday,
            start_time,
            end_time,
            slot_minutes,
            valid_from,
            is_active
        )
        SELECT
            v_doctor_id,
            v_weekday,
            TIME '09:00',
            TIME '11:00',
            30,
            v_first_date,
            true
        WHERE NOT EXISTS (
            SELECT 1
            FROM hospital.doctor_schedules
            WHERE doctor_id = v_doctor_id
              AND is_active
        );

        -- 5. Generate appointments for the next two weeks.
        v_slots := hospital.generate_slots(
            v_doctor_id,
            v_first_date,
            v_first_date + 13
        );

        RAISE NOTICE '%: % new slots created',
            r.doctor_name, v_slots;
    END LOOP;
END;
$$;

COMMIT;

-- Verify all doctor profiles and available slots.
SELECT
    d.full_name AS doctor_name,
    dep.name AS department,
    d.consultation_fee,
    COUNT(av.slot_id) AS available_slots
FROM hospital.doctors AS d
JOIN hospital.departments AS dep
    ON dep.department_id = d.department_id
LEFT JOIN hospital.available_slots AS av
    ON av.doctor_id = d.doctor_id
GROUP BY
    d.doctor_id,
    d.full_name,
    dep.name,
    d.consultation_fee
ORDER BY dep.name, d.full_name;