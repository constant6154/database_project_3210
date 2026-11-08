BEGIN;

DO $$
DECLARE
    v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Dhaka')::date;
    v_doctor_id bigint;
    v_weekday smallint;
    v_new_slots integer;
    r record;
BEGIN
    -- ISO weekdays: Monday = 1, ..., Sunday = 7.
    FOR r IN
        SELECT *
        FROM (VALUES
            ('Dr. Arif Rahman',       'Cardiology',    ARRAY[7, 2]),
            ('Dr. Farhana Ahmed',     'Medicine',      ARRAY[1, 3]),
            ('Dr. Nadia Islam',       'Dermatology',   ARRAY[1, 4]),
            ('Dr. Tanvir Hasan',      'Neurology',     ARRAY[2, 6]),
            ('Dr. Imran Hossain',     'Orthopedics',   ARRAY[7, 3]),
            ('Dr. Samira Chowdhury',  'Pediatrics',    ARRAY[1, 6]),
            ('Dr. Rezaul Karim',      'ENT',           ARRAY[2, 4]),
            ('Dr. Nusrat Jahan',      'Ophthalmology', ARRAY[3, 6]),
            ('Dr. Ayesha Siddiqua',   'Gynecology',    ARRAY[7, 4])
        ) AS timetable(doctor_name, department, weekdays)
    LOOP
        SELECT d.doctor_id INTO STRICT v_doctor_id
        FROM hospital.doctors AS d
        JOIN hospital.departments AS dep
          ON dep.department_id = d.department_id
        WHERE d.full_name = r.doctor_name
          AND dep.name = r.department;

        FOREACH v_weekday IN ARRAY r.weekdays LOOP
            -- Skip an existing active session that overlaps this time.
            INSERT INTO hospital.doctor_schedules (
                doctor_id, weekday, start_time, end_time,
                slot_minutes, valid_from
            )
            SELECT
                v_doctor_id, v_weekday, TIME '14:00', TIME '16:00',
                30, v_today
            WHERE NOT EXISTS (
                SELECT 1
                FROM hospital.doctor_schedules AS ds
                WHERE ds.doctor_id = v_doctor_id
                  AND ds.weekday = v_weekday
                  AND ds.is_active
                  AND (ds.valid_until IS NULL OR ds.valid_until >= v_today)
                  AND ds.start_time < TIME '16:00'
                  AND ds.end_time > TIME '14:00'
            );
        END LOOP;

        -- Generate from ALL this doctor's schedules, including mornings.
        v_new_slots := hospital.generate_slots(
            v_doctor_id, v_today, v_today + 27
        );

        RAISE NOTICE '%: % new slots generated', r.doctor_name, v_new_slots;
    END LOOP;
END;
$$;

COMMIT;